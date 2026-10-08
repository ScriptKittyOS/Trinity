# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Ironbank.Lint do
  @shortdoc "Checks the Iron Bank submission tree and the published image's base pins"

  @moduledoc """
  Checks `ci/ironbank/`, the Iron Bank submission tree, against the rules that can be checked
  without Iron Bank's pipeline, and `ci/headless/bases.env`, the published image's base pins
  (slice 130, AC2, AC2a, AC6 and AC6a; `docs/regulated/headless-image.md`).

      mix trinity.ironbank.lint               the tree as it stands; holds are allowed
      mix trinity.ironbank.lint --submission  also refuses every open hold (AC7's review)

  Every rule is checked on the files, never on the image: the image's own assertions are
  `mix trinity.image.inspect`. Each violation names the criterion it belongs to.

  * **AC2.** Every `FROM` takes its registry from `${BASE_REGISTRY}` or names an earlier stage;
    none names a registry host. Resolved against `ci/headless/bases.env`, every `FROM` of the
    published build carries an `@sha256:` digest. The manifest supplies every other variable a
    `FROM` uses and never `BASE_REGISTRY`, which is the pipeline's.
  * **AC2a.** No `ADD`; no `curl`, `wget` or URL anywhere in the Dockerfile or the submission's
    scripts, comments included, because Iron Bank rejects them "even if the code path never
    runs". Every file the Dockerfile copies from the context is a declared resource, a held one
    (`ci/headless/submission_holds.yaml`), or a file of the submission; every declared resource
    is used; each resource has a SHA-256 or SHA-512 digest.
  * **AC6.** No world-writable or SUID/SGID `chmod`, no `--nogpgcheck` or `gpgcheck=0`, no
    `rpm --import` from anywhere but a `gpg/` folder, nothing that writes `/etc/passwd`, and the
    final `USER` is a numeric UID of 1000 or more.
  * **AC6a.** The submission holds only the entries Iron Bank's repository-structure page
    names, the four it requires among them; no `conf/` (`config/` is the spelling, slice 130
    NOTES D-130-1); no `LABEL` in the Dockerfile; the manifest has the fields and labels Iron
    Bank's schema requires; its version and its OTP and Elixir resources agree with `mix.exs`
    and `.tool-versions`.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @submission "ci/ironbank"
  @bases "ci/headless/bases.env"
  @holds "ci/headless/submission_holds.yaml"

  # Iron Bank's repository-structure page (docs-ironbank.dso.mil/hardening/repository-structure/,
  # read 2026-10-08), plus the `gpg` folder its Dockerfile requirements name for imported keys.
  @allowed_entries ~w(Dockerfile Dockerfile.arm64 hardening_manifest.yaml testing_manifest.yaml
                      LICENSE README.md renovate.json trufflehog-config.yaml config documentation
                      scripts gpg)
  @required_entries ~w(Dockerfile hardening_manifest.yaml LICENSE README.md)

  # Iron Bank's schema, schema/hardening_manifest.schema.json, `labels`.
  @required_labels ~w(org.opencontainers.image.title org.opencontainers.image.description
                      org.opencontainers.image.licenses org.opencontainers.image.vendor
                      org.opencontainers.image.version)
  @allowed_labels @required_labels ++
                    ~w(org.opencontainers.image.url mil.dso.ironbank.image.keywords
                       mil.dso.ironbank.image.type mil.dso.ironbank.product.name)

  @from_variables ~r/^\$\{BASE_REGISTRY\}\/\$\{([A-Z0-9_]+)\}:\$\{([A-Z0-9_]+)\}$/
  @network_words ~r/\b(curl|wget)\b/i
  @url ~r{\b(?:https?|ftp)://}i
  @digest_lengths %{"sha256" => 64, "sha512" => 128}
  @pending "PENDING"

  @typedoc "Everything the rules read, gathered once so a test can plant a violation in it."
  @type tree :: %{
          dockerfile: String.t(),
          manifest: map(),
          scripts: [{Path.t(), String.t()}],
          entries: [String.t()],
          symlinks: [String.t()],
          bases_env: String.t(),
          holds: map(),
          tool_versions: String.t(),
          version: String.t()
        }

  @typedoc "One Dockerfile instruction: its first line number, keyword (upper case) and text."
  @type instruction :: {pos_integer(), String.t(), String.t()}

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [submission: :boolean])
    tree = read_tree(".")

    case violations(tree, submission: Keyword.get(opts, :submission, false)) do
      [] ->
        Mix.shell().info("trinity.ironbank.lint: OK (#{@submission}, #{@bases})")

      found ->
        Enum.each(found, &Mix.shell().error("FAIL #{&1}"))
        Mix.raise("trinity.ironbank.lint: #{length(found)} violation(s)")
    end
  end

  @doc "Reads the submission tree, the base pins, the holds and the versions they must agree with."
  @spec read_tree(Path.t()) :: tree()
  def read_tree(root) do
    sub = Path.join(root, @submission)
    entries = sub |> File.ls!() |> Enum.sort()

    %{
      dockerfile: File.read!(Path.join(sub, "Dockerfile")),
      manifest: yaml!(Path.join(sub, "hardening_manifest.yaml")),
      scripts: read_scripts(Path.join(sub, "scripts")),
      entries: entries,
      symlinks: Enum.filter(entries, &symlink?(Path.join(sub, &1))),
      bases_env: File.read!(Path.join(root, @bases)),
      holds: yaml!(Path.join(root, @holds)),
      tool_versions: File.read!(Path.join(root, ".tool-versions")),
      version: Mix.Project.config()[:version]
    }
  end

  @doc """
  Every violation in `tree`, as one line each naming its criterion. Empty when the tree passes.
  With `submission: true`, every open hold is a violation too.
  """
  @spec violations(tree(), keyword()) :: [String.t()]
  def violations(tree, opts \\ []) do
    instructions = instructions(tree.dockerfile)

    Enum.concat([
      from_violations(instructions, tree),
      network_violations(instructions, tree),
      resource_violations(instructions, tree),
      hardening_violations(instructions),
      layout_violations(instructions, tree),
      manifest_violations(tree),
      hold_violations(tree, Keyword.get(opts, :submission, false))
    ])
  end

  @doc """
  The Dockerfile's instructions, continuation lines joined and comment lines dropped, as
  `{first_line, KEYWORD, rest}`.
  """
  @spec instructions(String.t()) :: [instruction()]
  def instructions(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, &collect_line/2)
    |> then(fn {acc, open} -> if open, do: [open | acc], else: acc end)
    |> Enum.reverse()
    |> Enum.map(fn {n, body} ->
      [keyword | rest] = String.split(String.trim(body), ~r/\s+/, parts: 2)
      {n, String.upcase(keyword), Enum.join(rest)}
    end)
  end

  defp collect_line({line, n}, {acc, open}) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#"),
      do: {acc, open},
      else: continue_or_close(String.trim_trailing(line), n, acc, open)
  end

  defp continue_or_close(line, n, acc, open) do
    {start, body} = open || {n, ""}

    if String.ends_with?(line, "\\") do
      {acc, {start, body <> " " <> String.trim_trailing(line, "\\")}}
    else
      {[{start, body <> " " <> line} | acc], nil}
    end
  end

  @doc """
  The `FROM` instructions as `{line, reference, stage_name_or_nil}`, with `--platform` dropped.
  """
  @spec froms([instruction()]) :: [{pos_integer(), String.t(), String.t() | nil}]
  def froms(instructions) do
    for {n, "FROM", rest} <- instructions do
      words = rest |> String.split() |> Enum.reject(&String.starts_with?(&1, "--"))

      case words do
        [ref, as, name] when as in ["AS", "as", "As"] -> {n, ref, name}
        [ref | _] -> {n, ref, nil}
      end
    end
  end

  @doc "`KEY=VALUE` lines of an env file, comments and blank lines skipped."
  @spec env_pairs(String.t()) :: %{String.t() => String.t()}
  def env_pairs(text) do
    for line <- String.split(text, "\n"),
        line = String.trim(line),
        line != "" and not String.starts_with?(line, "#"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {key, value}
  end

  # AC2 -----------------------------------------------------------------------------------------

  defp from_violations(instructions, tree) do
    bases = env_pairs(tree.bases_env)
    args = Map.get(tree.manifest, "args", %{})

    instructions
    |> froms()
    |> Enum.reduce({[], MapSet.new()}, fn {n, ref, name}, {found, stages} ->
      stages_after = if name, do: MapSet.put(stages, name), else: stages

      if MapSet.member?(stages, ref) do
        {found, stages_after}
      else
        {found ++ base_from_violations(n, ref, bases, args), stages_after}
      end
    end)
    |> elem(0)
  end

  defp base_from_violations(n, ref, bases, args) do
    case Regex.run(@from_variables, ref) do
      [_, image_var, tag_var] ->
        manifest_args_violations(n, [image_var, tag_var], args) ++
          published_pin_violations(n, ref, bases)

      nil ->
        [
          "AC2: Dockerfile line #{n}: FROM #{ref} does not take its registry from " <>
            "${BASE_REGISTRY}/${IMAGE}:${TAG}; a registry named in the file is prohibited " <>
            "in an Iron Bank submission"
        ]
    end
  end

  defp manifest_args_violations(n, vars, args) do
    for var <- vars, not Map.has_key?(args, var) do
      "AC2: Dockerfile line #{n}: ${#{var}} is not set by hardening_manifest.yaml `args`, " <>
        "so Iron Bank's build would fall back to the Dockerfile default"
    end
  end

  defp published_pin_violations(n, ref, bases) do
    missing = for var <- ~w(BASE_REGISTRY) ++ vars_in(ref), not Map.has_key?(bases, var), do: var

    if missing != [] do
      ["AC2: Dockerfile line #{n}: #{@bases} does not set #{Enum.join(missing, ", ")}"]
    else
      resolved = Regex.replace(~r/\$\{([A-Z0-9_]+)\}/, ref, fn _, var -> bases[var] end)

      if resolved =~ ~r/@sha256:[0-9a-f]{64}$/ do
        []
      else
        [
          "AC2: Dockerfile line #{n}: the published build resolves FROM to #{resolved}, " <>
            "which is not pinned by digest (#{@bases})"
        ]
      end
    end
  end

  defp vars_in(ref), do: for([_, var] <- Regex.scan(~r/\$\{([A-Z0-9_]+)\}/, ref), do: var)

  # AC2a ----------------------------------------------------------------------------------------

  defp network_violations(instructions, tree) do
    adds =
      for {n, "ADD", _} <- instructions,
          do: "AC2a: Dockerfile line #{n}: ADD is prohibited; use COPY from the build context"

    texts = [{"Dockerfile", tree.dockerfile} | tree.scripts]

    words =
      for {path, text} <- texts,
          {line, n} <- text |> String.split("\n") |> Enum.with_index(1),
          reason <- network_reasons(line),
          do: "AC2a: #{path} line #{n}: #{reason}"

    adds ++ words
  end

  defp network_reasons(line) do
    words =
      for [_, word] <- Regex.scan(@network_words, line),
          do: "#{word} reaches the network; Iron Bank rejects it even in a branch never taken"

    urls = if line =~ @url, do: ["a URL; the build may not reference the internet"], else: []
    words ++ urls
  end

  defp resource_violations(instructions, tree) do
    declared = tree.manifest |> Map.get("resources", []) |> Enum.map(& &1["filename"])
    held = tree.holds |> Map.get("resources", []) |> Enum.map(& &1["filename"])
    copied = copy_sources(instructions)
    copied_names = Enum.map(copied, &elem(&1, 1))

    unknown =
      for {n, source} <- copied,
          source not in declared and source not in held and not submission_file?(source, tree) do
        "AC2a: Dockerfile line #{n}: COPY #{source} is not a resource declared in " <>
          "hardening_manifest.yaml, a held one, or a file of the submission"
      end

    unused =
      for name <- declared, name not in copied_names do
        "AC2a: resource #{name} is declared in hardening_manifest.yaml but never copied"
      end

    unknown ++ unused ++ digest_violations(tree.manifest)
  end

  defp submission_file?(source, tree) do
    case String.split(source, "/", parts: 2) do
      [dir, _] when dir in ["scripts", "config", "gpg"] -> dir in tree.entries
      _ -> false
    end
  end

  @doc "The build-context sources of every `COPY` without `--from`, as `{line, source}`."
  @spec copy_sources([instruction()]) :: [{pos_integer(), String.t()}]
  def copy_sources(instructions) do
    for {n, "COPY", rest} <- instructions,
        not String.contains?(rest, "--from="),
        words = rest |> String.split() |> Enum.reject(&String.starts_with?(&1, "--")),
        source <- Enum.drop(words, -1),
        do: {n, String.trim_trailing(source, "/")}
  end

  defp digest_violations(manifest) do
    for resource <- Map.get(manifest, "resources", []),
        reason <- resource_reasons(resource),
        do: "AC2a: resource #{resource["filename"] || inspect(resource)}: #{reason}"
  end

  defp resource_reasons(resource) do
    cond do
      not url?(resource["url"]) -> ["needs an http(s) url"]
      not bare_filename?(resource["filename"]) -> ["needs a filename with no directory"]
      true -> validation_reasons(resource["validation"] || %{})
    end
  end

  defp url?(url), do: is_binary(url) and url =~ ~r{^https?://.+}
  defp bare_filename?(name), do: is_binary(name) and not String.contains?(name, "/")

  defp validation_reasons(%{"type" => type} = validation)
       when is_map_key(@digest_lengths, type) do
    value = to_string(validation["value"])
    length = @digest_lengths[type]

    if value =~ ~r/^[0-9a-f]+$/ and byte_size(value) == length,
      do: [],
      else: ["its #{type} value is not #{length} lowercase hex digits"]
  end

  defp validation_reasons(_), do: ["needs a sha256 or sha512 validation"]

  # AC6 -----------------------------------------------------------------------------------------

  defp hardening_violations(instructions) do
    runs = for {n, "RUN", rest} <- instructions, do: {n, rest}

    run_violations =
      for {n, text} <- runs,
          reason <- run_reasons(text),
          do: "AC6: Dockerfile line #{n}: #{reason}"

    run_violations ++ final_user_violations(instructions)
  end

  defp run_reasons(text) do
    chmod_reasons(text) ++
      gpg_reasons(text) ++
      if(String.contains?(text, "/etc/passwd"),
        do: ["writes or changes /etc/passwd; add the user with useradd and leave its mode alone"],
        else: []
      )
  end

  defp chmod_reasons(text) do
    for args <- command_args(text, "chmod"),
        mode <- args,
        not String.starts_with?(mode, "-"),
        not String.contains?(mode, "/"),
        reason <- mode_reasons(mode),
        do: reason
  end

  @doc false
  @spec mode_reasons(String.t()) :: [String.t()]
  def mode_reasons(mode) do
    cond do
      mode =~ ~r/^[0-7]{3,4}$/ ->
        digits =
          mode
          |> String.pad_leading(4, "0")
          |> String.graphemes()
          |> Enum.map(&String.to_integer/1)

        numeric_mode_reasons(mode, digits)

      mode =~ ~r/^[ugoa]*[+=][rwxXst]+(,[ugoa]*[+=-][rwxXst]+)*$/ ->
        symbolic_mode_reasons(mode)

      true ->
        []
    end
  end

  defp numeric_mode_reasons(mode, [special, _user, _group, other]) do
    world =
      if Bitwise.band(other, 2) != 0, do: ["chmod #{mode} makes a file world-writable"], else: []

    setid =
      if Bitwise.band(special, 6) != 0, do: ["chmod #{mode} sets a SUID or SGID bit"], else: []

    world ++ setid
  end

  defp symbolic_mode_reasons(mode) do
    for clause <- String.split(mode, ","),
        [_, who, op, perms] <- [Regex.run(~r/^([ugoa]*)([+=-])(.*)$/, clause)],
        op in ["+", "="],
        reason <- symbolic_reason(mode, who, perms),
        do: reason
  end

  defp symbolic_reason(mode, who, perms) do
    world =
      if String.contains?(perms, "w") and (who == "" or who =~ ~r/[oa]/),
        do: ["chmod #{mode} makes a file world-writable"],
        else: []

    setid =
      if String.contains?(perms, "s"), do: ["chmod #{mode} sets a SUID or SGID bit"], else: []

    world ++ setid
  end

  defp gpg_reasons(text) do
    nogpg =
      if text =~ ~r/--nogpgcheck|gpgcheck\s*=\s*(0|false|no)\b/i,
        do: ["disables package signature checks; import the key from a gpg/ folder instead"],
        else: []

    imports =
      for args <- command_args(text, "rpm"),
          "--import" in args,
          path <- Enum.drop_while(args, &(&1 != "--import")) |> Enum.drop(1) |> Enum.take(1),
          not (path =~ ~r{(^|/)gpg/}),
          do: "rpm --import #{path} is not from a gpg/ folder"

    nogpg ++ imports
  end

  # The arguments of every invocation of `command` in a shell text, split at && || ; and |.
  defp command_args(text, command) do
    for segment <- String.split(text, ~r/&&|\|\||;|\|/),
        [cmd | args] <- [String.split(segment)],
        Path.basename(cmd) == command,
        do: args
  end

  defp final_user_violations(instructions) do
    final_stage =
      instructions
      |> Enum.reverse()
      |> Enum.take_while(fn {_, keyword, _} -> keyword != "FROM" end)

    case for({n, "USER", user} <- final_stage, do: {n, user}) do
      [] ->
        ["AC6: the final stage sets no USER, so the image runs as root"]

      [{n, user} | _] ->
        uid = user |> String.split(":") |> hd()

        if uid =~ ~r/^\d+$/ and String.to_integer(uid) >= 1000,
          do: [],
          else: [
            "AC6: Dockerfile line #{n}: the final USER #{user} is not a numeric UID of 1000 or more"
          ]
    end
  end

  # AC6a ----------------------------------------------------------------------------------------

  defp layout_violations(instructions, tree) do
    missing =
      for e <- @required_entries,
          e not in tree.entries,
          do: "AC6a: #{@submission}/#{e} is required"

    stray =
      for e <- tree.entries, e not in @allowed_entries do
        hint = if e == "conf", do: " (the configuration directory is config/)", else: ""
        "AC6a: #{@submission}/#{e} is not part of Iron Bank's repository structure#{hint}"
      end

    links =
      for e <- tree.symlinks, do: "AC6a: #{@submission}/#{e} is a symlink; their lint refuses one"

    labels =
      for {n, "LABEL", _} <- instructions,
          do: "AC6a: Dockerfile line #{n}: LABEL belongs in hardening_manifest.yaml"

    missing ++ stray ++ links ++ labels
  end

  defp manifest_violations(tree) do
    m = tree.manifest

    Enum.concat([
      if(m["apiVersion"] == "v1", do: [], else: ["AC6a: manifest apiVersion must be v1"]),
      name_violations(m["name"]),
      tag_violations(m["tags"], tree.version),
      args_violations(m["args"]),
      label_violations(m["labels"], tree.version),
      maintainer_violations(m["maintainers"]),
      toolchain_violations(m, tree.tool_versions)
    ])
  end

  defp name_violations(name) when is_binary(name) do
    if name =~ ~r{^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$} and
         not String.starts_with?(name, "ironbank/"),
       do: [],
       else: [
         "AC6a: manifest name #{inspect(name)} is not a registry path without its domain or ironbank/"
       ]
  end

  defp name_violations(_), do: ["AC6a: manifest name is missing"]

  defp tag_violations([first | _] = tags, version) when length(tags) <= 10 do
    cond do
      first == "latest" ->
        ["AC6a: the first manifest tag may not be latest"]

      first != version ->
        ["AC6a: the first manifest tag #{first} is not mix.exs's version #{version}"]

      true ->
        []
    end
  end

  defp tag_violations(_, _), do: ["AC6a: manifest tags must be a list of one to ten"]

  defp args_violations(args) when is_map(args) do
    required =
      for a <- ~w(BASE_IMAGE BASE_TAG),
          not Map.has_key?(args, a),
          do: "AC6a: manifest args lack #{a}"

    registry =
      if Map.has_key?(args, "BASE_REGISTRY"),
        do: ["AC6a: manifest args may not set BASE_REGISTRY; the pipeline does"],
        else: []

    required ++ registry
  end

  defp args_violations(_), do: ["AC6a: manifest args are missing"]

  defp label_violations(labels, version) when is_map(labels) do
    missing =
      for l <- @required_labels,
          not Map.has_key?(labels, l),
          do: "AC6a: manifest label #{l} is required"

    unknown =
      for {l, _} <- labels,
          l not in @allowed_labels,
          do: "AC6a: manifest label #{l} is not in Iron Bank's schema"

    type =
      if labels["mil.dso.ironbank.image.type"] in [nil, "opensource", "commercial"],
        do: [],
        else: ["AC6a: mil.dso.ironbank.image.type must be opensource or commercial"]

    stale =
      if labels["org.opencontainers.image.version"] == version,
        do: [],
        else: ["AC6a: label org.opencontainers.image.version is not mix.exs's version #{version}"]

    missing ++ unknown ++ type ++ stale
  end

  defp label_violations(_, _), do: ["AC6a: manifest labels are missing"]

  defp maintainer_violations([_ | _] = maintainers) do
    for m <- maintainers,
        key <- ~w(name username),
        not (is_binary(m[key]) and m[key] != ""),
        do: "AC6a: a manifest maintainer lacks #{key}"
  end

  defp maintainer_violations(_), do: ["AC6a: the manifest names no maintainer"]

  defp toolchain_violations(manifest, tool_versions) do
    files = manifest |> Map.get("resources", []) |> Enum.map(& &1["filename"])
    tools = env_pairs(String.replace(tool_versions, " ", "="))
    otp = tools["erlang"]
    elixir = tools["elixir"] |> to_string() |> String.replace(~r/-otp-\d+$/, "")
    major = otp |> to_string() |> String.split(".") |> hd()

    for {expected, what} <- [
          {"otp_src_#{otp}.tar.gz", "OTP #{otp}"},
          {"elixir-#{elixir}-otp-#{major}.zip", "Elixir #{elixir}"}
        ],
        expected not in files,
        do: "AC6a: no resource #{expected}, the #{what} that .tool-versions names"
  end

  # Holds ---------------------------------------------------------------------------------------

  defp hold_violations(tree, submission?) do
    resources = Map.get(tree.holds, "resources") || []
    fields = Map.get(tree.holds, "fields") || []

    Enum.concat([
      malformed_holds(resources ++ fields),
      stale_resource_holds(resources, tree),
      field_hold_violations(fields, tree.manifest),
      if(submission?, do: open_holds(resources ++ fields), else: [])
    ])
  end

  defp malformed_holds(holds) do
    for hold <- holds,
        key <- ~w(owner opened lift),
        not well_formed?(key, hold[key]),
        do: "holds: #{hold["filename"] || hold["path"]} lacks a valid #{key}"
  end

  defp stale_resource_holds(resources, tree) do
    declared = tree.manifest |> Map.get("resources", []) |> Enum.map(& &1["filename"])
    copied = tree.dockerfile |> instructions() |> copy_sources() |> Enum.map(&elem(&1, 1))

    for %{"filename" => f} <- resources, f in declared or f not in copied do
      state = if f in declared, do: "now declared", else: "not copied"
      "holds: #{f} is held but is #{state}; remove the hold"
    end
  end

  defp field_hold_violations(fields, manifest) do
    pending = pending_paths(manifest, [])
    held = Enum.map(fields, & &1["path"])

    for(p <- pending, p not in held, do: "holds: manifest #{p} is #{@pending} with no hold") ++
      for p <- held, p not in pending, do: "holds: #{p} is held but no longer #{@pending}"
  end

  defp open_holds(holds) do
    for h <- holds, do: "AC7: open hold #{h["filename"] || h["path"]}: #{h["lift"]}"
  end

  defp well_formed?("opened", value),
    do: is_binary(value) and match?({:ok, _}, Date.from_iso8601(value))

  defp well_formed?(_key, value), do: is_binary(value) and String.trim(value) != ""

  # The paths of every manifest value containing PENDING, as `maintainers[0].username`.
  defp pending_paths(value, path) when is_map(value) do
    Enum.flat_map(value, fn {k, v} -> pending_paths(v, path ++ [k]) end)
  end

  defp pending_paths(value, path) when is_list(value) do
    value |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> pending_paths(v, path ++ [i]) end)
  end

  defp pending_paths(value, path) when is_binary(value) do
    if String.contains?(value, @pending), do: [render_path(path)], else: []
  end

  defp pending_paths(_, _), do: []

  defp render_path(path) do
    Enum.reduce(path, "", fn
      i, acc when is_integer(i) -> acc <> "[#{i}]"
      k, "" -> k
      k, acc -> acc <> "." <> k
    end)
  end

  # Files ---------------------------------------------------------------------------------------

  defp read_scripts(dir) do
    if File.dir?(dir) do
      for path <- Path.wildcard(Path.join(dir, "**/*")),
          File.regular?(path),
          do: {path, File.read!(path)}
    else
      []
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  defp yaml!(path) do
    {:ok, data} = YamlElixir.read_from_file(path)
    data
  end
end
