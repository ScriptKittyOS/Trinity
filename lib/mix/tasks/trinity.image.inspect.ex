# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.Inspect do
  @shortdoc "Asserts the built headless image's user and layer contents (slice 130, AC1 and AC6)"

  @moduledoc """
  Inspects a **built** image, never its Dockerfile, so a later layer that reverts a property
  fails here whatever the recipe says (slice 130, AC1 and AC6; `docs/regulated/headless-image.md`).

      mix trinity.image.inspect IMAGE [--base REF] [--allowances PATH]

  `--base` defaults to the runtime base `ci/headless/bases.env` pins. The image's layers come from
  `docker save`; the layers it adds over its base are found by diff ID, and every entry of every
  added layer is checked, including entries a later layer deletes, because a deleted file is still
  in the image's tarball.

  **AC1.** The image's configured user is not root: a numeric UID of 1000 or more, or a name the
  image's own `/etc/passwd` resolves to one.

  **AC6, in the layers this image adds.** No package manager; no build tool (a compiler, a linker,
  `make`, Mix); no build-time Elixir library carried as a release application; no shell history;
  no documentation (`/usr/share/{doc,man,info}`, and files named README, CHANGELOG, CHANGES,
  HISTORY or NEWS, outside `/usr/share/licenses`, which is licence text); no certificate that differs from the base's file at the same path; no SUID or
  SGID file; no world-writable file or unsticky world-writable directory. `/etc/passwd` keeps the
  base's mode, owner and group.

  **AC6, anywhere in the image, base included.** No private key, no keystore, no Erlang
  distribution cookie.

  Base content that would otherwise be a finding is printed as inherited, because Iron Bank's rule
  is not to remove what the base ships (slice 130 NOTES, D-130-5). A finding of an allowable kind
  (`certificate`, `documentation`, `build_library`, `private_key`) may be allowed by a row in
  `ci/headless/image_allowances.yaml` that names the path (or a directory prefix ending in `/`) and
  a reason; a `private_key` allowance must name the exact file and its SHA-256. An allowance that
  allows nothing fails as stale (D-130-10). Nothing else can be allowed.

  One more property, not an AC, checked because slice 130 found its absence in the slice 061
  image: `RELEASE_DISTRIBUTION=none`, so the release starts no distribution listener.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @allowances "ci/headless/image_allowances.yaml"
  @allowable ~w(certificate documentation build_library private_key)

  @package_managers ~w(rpm rpm2cpio rpmdb dnf dnf-3 dnf4 dnf5 yum microdnf apt apt-get dpkg apk
                       pip pip3 gem npm)
  @build_tools ~w(gcc cc c++ g++ cpp clang clang++ ld ld.bfd ld.gold as make gmake cmake autoconf
                  automake libtool rustc cargo go javac pkg-config)
  # Elixir libraries whose only job is building or packaging, which a release can still carry as
  # applications when a dependency does not mark them `runtime: false`.
  @build_libraries ~w(mix rustler elixir_make cc_precompiler burrito ex_tauri igniter fine)
  @histories ~w(.bash_history .sh_history .ash_history .zsh_history .history .python_history
                .mysql_history .psql_history .lesshst .viminfo .node_repl_history .erlang_history)
  @key_extensions ~w(.key .p12 .pfx .jks .keystore)
  @certificate_extensions ~w(.crt .cer .der)
  @documentation_name ~r/^(README|CHANGELOG|CHANGES|HISTORY|NEWS)(\.(md|txt|rst|markdown))?$/i
  # A PEM block, not its header: the header strings alone are constants inside every TLS library
  # and in OTP's own public_key (measured on the slice 061 image: libgnutls, libssh2 and
  # pubkey_pem.beam matched a header-only pattern, and only libgnutls carries a key). A block is
  # the header, any RFC 1421 header lines, then a base64 body.
  @private_key ~r/-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----\r?\n(?:[A-Za-z-]+:[^\n]*\n)*\r?\n?[A-Za-z0-9+\/]{40}/
  @certificate ~r/-----BEGIN (?:TRUSTED )?CERTIFICATE-----\r?\n[A-Za-z0-9+\/]{40}/
  @chunk 1_048_576
  # Bytes carried from one chunk into the next, longer than the longest span either pattern needs
  # to see, so a block that straddles a chunk boundary is still found.
  @carry 512

  @typedoc "One tar entry, as `:erl_tar.table/2` reports it with `:verbose`."
  @type entry :: %{
          path: String.t(),
          type: atom(),
          mode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer()
        }

  @typedoc "An unpacked layer: its entries and the directory its contents were written to."
  @type layer :: %{entries: [entry()], dir: Path.t()}

  @typedoc """
  A finding before allowances: the criterion, the path, its kind and the reason, plus, for a
  private key, the SHA-256 of each PEM block found.
  """
  @type finding :: %{
          ac: String.t(),
          path: String.t(),
          kind: String.t(),
          reason: String.t(),
          blocks: [String.t()]
        }

  @typedoc "What `check/1` reads."
  @type input :: %{
          config: map(),
          base: [layer()],
          added: [layer()],
          allowances: [map()]
        }

  @typedoc "What `check/1` returns."
  @type result :: %{violations: [String.t()], allowed: [String.t()], inherited: [String.t()]}

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [base: :string, allowances: :string])
    image = List.first(args) || Mix.raise("usage: mix trinity.image.inspect IMAGE [--base REF]")
    base = opts[:base] || pinned_base()

    work =
      Path.join(System.tmp_dir!(), "trinity-image-inspect-#{System.unique_integer([:positive])}")

    try do
      {config, base_layers, added_layers} = unpack(image, base, work)

      %{config: config, base: base_layers, added: added_layers}
      |> Map.put(:allowances, read_allowances(opts[:allowances] || @allowances))
      |> check()
      |> report(image, base)
    after
      _ = System.cmd("chmod", ["-R", "u+rwX", work], stderr_to_stdout: true)
      File.rm_rf(work)
    end
  end

  @doc """
  Every finding for `input`: violations, each naming its criterion; the findings allowances
  allowed, with their reasons; and base content that would otherwise be a finding.
  """
  @spec check(input()) :: result()
  def check(input) do
    layers = input.base ++ input.added
    base_files = files_by_path(input.base)

    findings =
      Enum.flat_map(input.added, &added_findings(&1, base_files)) ++
        Enum.flat_map(layers, &secret_findings/1)

    {allowed, refused} = Enum.split_with(findings, &allowance_for(&1, input.allowances))

    stale =
      for a <- input.allowances, not Enum.any?(allowed, &(allowance_for(&1, [a]) != nil)), do: a

    violations =
      Enum.concat([
        user_violations(input.config, layers),
        distribution_violations(input.config),
        Enum.map(refused, &"#{&1.ac}: /#{&1.path}: #{&1.reason}"),
        passwd_violations(
          final_entry(layers, "etc/passwd"),
          final_entry(input.base, "etc/passwd")
        ),
        allowance_violations(input.allowances),
        Enum.map(
          stale,
          &"AC6: allowance #{&1["path"]} allows nothing in this image; remove it from #{@allowances}"
        )
      ])

    %{
      violations: Enum.uniq(violations),
      allowed:
        Enum.map(
          allowed,
          &"/#{&1.path}: #{&1.reason} (#{allowance_for(&1, input.allowances)["reason"]})"
        ),
      inherited: Enum.flat_map(input.base, &inherited/1)
    }
  end

  # AC1 -----------------------------------------------------------------------------------------

  defp user_violations(config, layers) do
    user = get_in(config, ["config", "User"]) || ""
    name = user |> String.split(":") |> hd()

    cond do
      name == "" ->
        ["AC1: the image sets no user, so it runs as root"]

      name =~ ~r/^\d+$/ ->
        uid_violation(String.to_integer(name), user)

      true ->
        case passwd_uid(layers, name) do
          nil -> ["AC1: the image's user #{user} is not in its /etc/passwd"]
          uid -> uid_violation(uid, user)
        end
    end
  end

  defp uid_violation(0, user), do: ["AC1: the image's user #{user} is root"]

  defp uid_violation(uid, user) when uid < 1000,
    do: ["AC1: the image's user #{user} has UID #{uid}, below 1000"]

  defp uid_violation(_uid, _user), do: []

  defp passwd_uid(layers, name) do
    with %{file: file} <- final_entry(layers, "etc/passwd"),
         {:ok, text} <- File.read(file) do
      text |> String.split("\n") |> Enum.find_value(&uid_on_line(&1, name))
    else
      _ -> nil
    end
  end

  defp uid_on_line(line, name) do
    case String.split(line, ":") do
      [^name, _, uid | _] -> String.to_integer(uid)
      _ -> nil
    end
  end

  defp distribution_violations(config) do
    if "RELEASE_DISTRIBUTION=none" in (get_in(config, ["config", "Env"]) || []),
      do: [],
      else: [
        "hardening: RELEASE_DISTRIBUTION is not none, so the release starts a distribution listener"
      ]
  end

  # AC6, the layers this image adds -------------------------------------------------------------

  defp added_findings(layer, base_files) do
    for entry <- layer.entries,
        not whiteout?(entry.path),
        file = Path.join(layer.dir, entry.path),
        {kind, reason} <- entry_findings(entry, file, base_files),
        do: %{ac: "AC6", path: entry.path, kind: kind, reason: reason, blocks: []}
  end

  defp entry_findings(entry, file, base_files) do
    name = Path.basename(entry.path)
    in_bin? = entry.path =~ ~r{(^|/)s?bin/[^/]+$}

    Enum.concat([
      if(in_bin? and name in @package_managers,
        do: [{"package_manager", "a package manager"}],
        else: []
      ),
      if(in_bin? and name in @build_tools, do: [{"build_tool", "a build tool"}], else: []),
      build_library_findings(entry),
      if(name in @histories, do: [{"history", "shell history"}], else: []),
      documentation_findings(entry),
      mode_findings(entry),
      certificate_findings(entry, file, base_files)
    ])
  end

  defp build_library_findings(%{type: :directory, path: path}) do
    case Regex.run(~r{(?:^|/)lib/([a-z_]+)-[0-9][^/]*$}, path) do
      [_, app] when app in @build_libraries ->
        [{"build_library", "#{app}, a build-time library, carried as a release application"}]

      _ ->
        []
    end
  end

  defp build_library_findings(_), do: []

  # /usr/share/licenses is licence text, which a redistributed package has to keep.
  defp documentation_findings(%{type: :regular, path: path}) do
    if not String.starts_with?(path, "usr/share/licenses/") and
         (path =~ ~r{(^|/)usr/share/(doc|man|info)/} or Path.basename(path) =~ @documentation_name),
       do: [{"documentation", "documentation"}],
       else: []
  end

  defp documentation_findings(_), do: []

  defp mode_findings(%{type: :symlink}), do: []

  defp mode_findings(entry) do
    setid =
      if entry.type == :regular and Bitwise.band(entry.mode, 0o6000) != 0,
        do: [{"setid", "SUID or SGID bit set (mode #{octal(entry.mode)})"}],
        else: []

    world =
      cond do
        Bitwise.band(entry.mode, 0o002) == 0 -> []
        entry.type == :directory and Bitwise.band(entry.mode, 0o1000) != 0 -> []
        true -> [{"world_writable", "world-writable (mode #{octal(entry.mode)})"}]
      end

    setid ++ world
  end

  defp certificate_findings(%{type: :regular} = entry, file, base_files) do
    cond do
      same_as_base?(file, base_files[entry.path]) ->
        []

      Path.extname(entry.path) in @certificate_extensions ->
        [{"certificate", "certificate material"}]

      contains?(file, @certificate) ->
        [{"certificate", "certificate material"}]

      true ->
        []
    end
  end

  defp certificate_findings(_, _, _), do: []

  # AC6, anywhere in the image ------------------------------------------------------------------

  defp secret_findings(layer) do
    for %{type: :regular} = entry <- layer.entries,
        file = Path.join(layer.dir, entry.path),
        {kind, reason} <- secret_reasons(entry.path, file),
        do: %{
          ac: "AC6",
          path: entry.path,
          kind: kind,
          reason: reason,
          blocks: key_blocks(kind, file)
        }
  end

  defp secret_reasons(path, file) do
    name = Path.basename(path)

    cond do
      name == ".erlang.cookie" or path =~ ~r{(^|/)releases/COOKIE$} ->
        [
          {"cookie",
           "an Erlang distribution cookie, a credential everyone who pulls the image would hold"}
        ]

      name =~ ~r/^(id_(rsa|dsa|ecdsa|ed25519)|ssh_host_.*_key)$/ or
          Path.extname(name) in @key_extensions ->
        [{"key_file", "key material by its name"}]

      contains?(file, @private_key) ->
        [{"private_key", "a private key"}]

      true ->
        []
    end
  end

  defp passwd_violations(nil, _), do: ["AC6: the image has no /etc/passwd"]
  defp passwd_violations(_, nil), do: []

  defp passwd_violations(final, base) do
    fields = fn e -> {octal(Bitwise.band(e.mode, 0o7777)), e.uid, e.gid} end

    if fields.(final) == fields.(base),
      do: [],
      else: [
        "AC6: /etc/passwd is mode, owner, group #{inspect(fields.(final))}; the base's is #{inspect(fields.(base))}"
      ]
  end

  # Allowances ----------------------------------------------------------------------------------

  # The allowance that allows `finding`, or nil.
  defp allowance_for(finding, allowances) do
    Enum.find(allowances, fn a ->
      finding.kind in List.wrap(a["kinds"]) and finding.kind in @allowable and
        path_matches?(a["path"], finding.path) and digest_matches?(a, finding)
    end)
  end

  defp path_matches?(path, entry) when is_binary(path) do
    target = "/" <> entry
    # A prefix ending in / covers the directory itself and everything under it.
    if String.ends_with?(path, "/"),
      do: String.starts_with?(target <> "/", path),
      else: target == path
  end

  defp path_matches?(_, _), do: false

  # A private key is allowed only when every PEM block in the file is one the allowance names by
  # its SHA-256, so another key in the same file, or a changed one, fails again.
  defp digest_matches?(a, %{kind: "private_key", blocks: blocks}) do
    blocks != [] and Enum.all?(blocks, &(&1 in List.wrap(a["sha256"])))
  end

  defp digest_matches?(_a, _finding), do: true

  @private_key_block ~r/-----BEGIN ((?:[A-Z0-9]+ )*)PRIVATE KEY-----.*?-----END \1PRIVATE KEY-----/s

  # The SHA-256 of each private key PEM block in the file, header to footer inclusive.
  defp key_blocks("private_key", file) do
    file
    |> File.read!()
    |> then(&Regex.scan(@private_key_block, &1))
    |> Enum.map(fn [block | _] -> :crypto.hash(:sha256, block) |> Base.encode16(case: :lower) end)
  end

  defp key_blocks(_kind, _file), do: []

  defp allowance_violations(allowances) do
    for a <- allowances,
        reason <- allowance_problems(a),
        do: "AC6: allowance #{inspect(a["path"])}: #{reason}"
  end

  defp allowance_problems(a) do
    kinds = List.wrap(a["kinds"])

    Enum.concat([
      if(is_binary(a["path"]) and String.starts_with?(a["path"], "/"),
        do: [],
        else: ["needs an absolute path"]
      ),
      if(kinds != [] and Enum.all?(kinds, &(&1 in @allowable)),
        do: [],
        else: ["kinds must be some of #{Enum.join(@allowable, ", ")}"]
      ),
      if(is_binary(a["reason"]) and String.trim(a["reason"]) != "",
        do: [],
        else: ["needs a reason"]
      ),
      private_key_problems(a, kinds)
    ])
  end

  defp private_key_problems(a, kinds) do
    cond do
      "private_key" not in kinds ->
        []

      String.ends_with?(to_string(a["path"]), "/") ->
        ["a private_key allowance must name one file, not a directory"]

      not (a["sha256"] |> List.wrap() |> Enum.all?(&(to_string(&1) =~ ~r/^[0-9a-f]{64}$/))) or
          a["sha256"] in [nil, []] ->
        ["a private_key allowance must give the SHA-256 of each PEM block it allows"]

      true ->
        []
    end
  end

  defp inherited(layer) do
    for %{type: :regular} = entry <- layer.entries,
        what = inherited_kind(entry, Path.join(layer.dir, entry.path)),
        what != nil,
        do: "/#{entry.path}: #{what}"
  end

  defp inherited_kind(entry, file) do
    cond do
      entry.path =~ ~r{(^|/)usr/share/(doc|man|info)/} -> "documentation"
      Path.extname(entry.path) in @certificate_extensions -> "certificate material"
      entry.path =~ ~r{^etc/pki/rpm-gpg/} -> "an RPM signing public key"
      contains?(file, @certificate) -> "certificate material"
      true -> nil
    end
  end

  # Layers --------------------------------------------------------------------------------------

  @doc """
  Unpacks `image` and `base` from `docker save` into `work`: the image's config, its base layers
  and the layers it adds. Fails unless the base's layers are a prefix of the image's.
  """
  @spec unpack(String.t(), String.t(), Path.t()) :: {map(), [layer()], [layer()]}
  def unpack(image, base, work) do
    File.mkdir_p!(work)
    {image_config, image_layers} = save_and_read(image, Path.join(work, "image"))
    {_base_config, base_layers} = save_and_read(base, Path.join(work, "base"))
    base_ids = Enum.map(base_layers, &elem(&1, 0))
    image_ids = Enum.map(image_layers, &elem(&1, 0))

    unless Enum.take(image_ids, length(base_ids)) == base_ids do
      Mix.raise(
        "#{image} is not built on #{base}: the base's layers are not a prefix of the image's"
      )
    end

    to_layer = fn {_id, tar, dir} -> read_layer(tar, dir) end
    added = Enum.drop(image_layers, length(base_ids))
    {image_config, Enum.map(base_layers, to_layer), Enum.map(added, to_layer)}
  end

  defp save_and_read(ref, dir) do
    File.mkdir_p!(dir)
    archive = Path.join(dir, "image.tar")
    {out, status} = System.cmd("docker", ["save", ref, "-o", archive], stderr_to_stdout: true)
    if status != 0, do: Mix.raise("docker save #{ref} failed (#{status}): #{out}")

    :ok = :erl_tar.extract(String.to_charlist(archive), cwd: String.to_charlist(dir))
    [manifest] = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    config = dir |> Path.join(manifest["Config"]) |> File.read!() |> Jason.decode!()

    layers =
      manifest["Layers"]
      |> Enum.zip(config["rootfs"]["diff_ids"])
      |> Enum.with_index()
      |> Enum.map(fn {{tar, id}, i} ->
        {id, Path.join(dir, tar), Path.join(dir, "layer-#{i}")}
      end)

    {config, layers}
  end

  @doc """
  A layer tarball's entries, with its contents written under `dir` for reading. The entries
  (modes, owners) come from the tarball itself; the unpacked copy is only read for content, so it
  is unpacked with permissions that let a non-root user read it and remove it afterwards.
  """
  @spec read_layer(Path.t(), Path.t()) :: layer()
  def read_layer(tar, dir) do
    {:ok, table} = :erl_tar.table(String.to_charlist(tar), [:verbose])
    File.mkdir_p!(dir)

    {out, status} =
      System.cmd(
        "tar",
        [
          "-x",
          "--no-same-owner",
          "--no-same-permissions",
          "--exclude=dev/*",
          "-f",
          tar,
          "-C",
          dir
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("unpacking #{tar} failed (#{status}): #{out}")
    # Directories a layer ships read-only are made writable for the owner, so the copy can be
    # read through and removed afterwards.
    {_, 0} = System.cmd("chmod", ["-R", "u+rwX", dir])

    entries =
      for {name, type, _size, _mtime, mode, uid, gid} <- table do
        path = name |> to_string() |> String.trim_leading("./") |> String.trim_trailing("/")
        %{path: path, type: type, mode: mode, uid: uid, gid: gid}
      end

    %{entries: entries, dir: dir}
  end

  defp files_by_path(layers) do
    for layer <- layers, %{type: :regular} = e <- layer.entries, into: %{} do
      {e.path, Path.join(layer.dir, e.path)}
    end
  end

  defp final_entry(layers, path) do
    layers
    |> Enum.flat_map(fn layer ->
      for e <- layer.entries, e.path == path, do: Map.put(e, :file, Path.join(layer.dir, e.path))
    end)
    |> List.last()
  end

  defp whiteout?(path), do: path |> Path.basename() |> String.starts_with?(".wh.")

  defp same_as_base?(_file, nil), do: false

  defp same_as_base?(file, base_file) do
    digest = digest(file)
    digest != nil and digest == digest(base_file)
  end

  # nil for anything not unpacked as a regular file (device nodes under dev/ are not unpacked).
  defp digest(file) do
    if File.regular?(file) do
      file
      |> File.stream!(@chunk)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
    end
  end

  # True when the file's bytes match `pattern`, read in overlapping chunks so a block that
  # straddles a chunk boundary is still found; a file that cannot be read is not a match.
  defp contains?(file, pattern) do
    case File.open(file, [:read, :binary]) do
      {:ok, io} ->
        try do
          scan(io, pattern, "")
        after
          File.close(io)
        end

      _ ->
        false
    end
  end

  defp scan(io, pattern, carry) do
    case IO.binread(io, @chunk) do
      data when is_binary(data) ->
        window = carry <> data
        keep = min(@carry, byte_size(window))

        Regex.match?(pattern, window) or
          scan(io, pattern, binary_part(window, byte_size(window) - keep, keep))

      _ ->
        false
    end
  end

  defp octal(mode), do: "0" <> Integer.to_string(mode, 8)

  defp read_allowances(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> (data || %{}) |> Map.get("allowances", []) |> List.wrap()
      {:error, _} -> Mix.raise("cannot read #{path}")
    end
  end

  defp pinned_base do
    env = "ci/headless/bases.env" |> File.read!() |> Mix.Tasks.Trinity.Ironbank.Lint.env_pairs()
    "#{env["BASE_REGISTRY"]}/#{env["BASE_IMAGE"]}:#{env["BASE_TAG"]}"
  end

  defp report(%{violations: violations, allowed: allowed, inherited: inherited}, image, base) do
    Enum.each(inherited, &Mix.shell().info("inherited from the base: #{&1}"))
    Enum.each(allowed, &Mix.shell().info("allowed: #{&1}"))

    Mix.shell().info(
      "trinity.image.inspect: #{image} on #{base}: #{length(inherited)} inherited, " <>
        "#{length(allowed)} allowed, #{length(violations)} violation(s)"
    )

    case violations do
      [] ->
        Mix.shell().info("trinity.image.inspect: OK")

      found ->
        Enum.each(found, &Mix.shell().error("FAIL #{&1}"))
        Mix.raise("trinity.image.inspect: #{length(found)} violation(s) in #{image}")
    end
  end
end
