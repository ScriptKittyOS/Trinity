# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Guard do
  @moduledoc """
  The one judge of a path a tool was given (slice 135, docs/07 "Filesystem"). A tool the agent
  calls cannot read or write a secret or a database file of Trinity's own, by any path: direct,
  `..`, a symlink, a hard link, `/proc/self/fd`, or a bind mount. The process still *uses* its keys
  through their APIs; it can no longer *read* them through a tool.

  ## What is protected

  The **data directory** and the **secrets directory** (`Trinity.Paths`), by path; and, by inode, an
  inventory of `(st_dev, st_ino)` taken at every call: every entry under the secrets directory and
  the configured keys directory, the database files with their journals, the MCP token file and
  OAuth store when configured elsewhere, and the data and secrets directories themselves. The
  inventory is what catches a hard link and a bind mount, which no path comparison can see.

  ## The checks, in order (the deny-list is the second line, never the first)

  1. The path is expanded lexically against the canonical working directory (`..` included). A
     configured root's own spelling is rewritten to its canonical form, so a root reached through a
     symlinked prefix still works.
  2. `/proc` and `/dev` are refused.
  3. Every existing component is `lstat`ed: a symlink anywhere is refused (no link is followed, so
     the lexical path is the physical one), and a component whose `(dev, ino)` is in the inventory
     is refused (a bind mount of the data or secrets directory).
  4. A path under the data directory or the secrets directory is refused.
  5. The final component: anything not a regular file or a directory is refused, and a regular file
     with `nlink > 1` is refused unless `config :trinity, :fs, allow_hard_links: true`.
  6. The deny-list, on the canonical basename: `#{Enum.join(~w(*.key *.db *.db-wal *.db-shm *.sqlite* .env* id_* *.pem), ", ")}`.
  7. Inside a root (configured, or the session's working directory) the verdict is `:allow`;
     outside, `:ask` (slice 022's rule: the tool escalates, the gate decides).

  **At open** (`open/3`), the file is opened and its descriptor `fstat`ed (`:file.read_file_info/1`
  on the open device, which is `fstat`: measured in slice 135 NOTES): an inventoried `(dev, ino)`,
  `nlink > 1`, a non-regular file, or an inode other than the one the walk saw is refused. A swap
  between the walk and the open therefore cannot hand a tool a protected inode.

  No NIF: `file:open/2` has no `O_NOFOLLOW` or `openat2`, and the post-open check closes the window
  for every protected inode (slice 135 NOTES, "Decision: no NIF").

  ## Roots fail closed

  `check_roots/2` refuses a root equal to, an ancestor of, or a descendant of the data directory or
  the secrets directory; `Trinity.Application` asks it before any child starts, in every profile,
  and the Settings page asks it before saving a folder. At call time a root that overlaps either is
  not a root.
  """

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @deny_list ~w(*.key *.db *.db-wal *.db-shm *.sqlite* .env* id_* *.pem)
  @refused_trees ["/proc", "/dev"]
  @inventory_cap 20_000

  @typedoc "How a tool means to use a path."
  @type mode :: :read | :write | :dir

  @typedoc "The guard's answer for one path."
  @type verdict :: %{
          requested: String.t(),
          canonical: String.t() | nil,
          dev: non_neg_integer() | nil,
          ino: non_neg_integer() | nil,
          nlink: non_neg_integer() | nil,
          type: atom() | nil,
          root: String.t() | nil,
          rule: String.t() | nil,
          decision: :allow | :ask | :deny
        }

  @typedoc "What one call is judged against, taken fresh at the call."
  @type scope :: %{
          data_dir: String.t(),
          secrets_dir: String.t(),
          protected: [String.t()],
          inventory: %{{non_neg_integer(), non_neg_integer()} => String.t()},
          roots: [{String.t(), String.t()}],
          cwd: String.t() | nil,
          allow_hard_links: boolean()
        }

  @doc "The deny-list, as glob patterns over the canonical basename."
  @spec deny_list() :: [String.t()]
  def deny_list, do: @deny_list

  ## Boot

  @doc """
  Refuses a root that is equal to, an ancestor of, or a descendant of a protected directory.
  `roots` and `protected` (`[{name, dir}]`) are compared in canonical form.
  """
  @spec check_roots([String.t()], [{atom(), String.t()}]) ::
          :ok
          | {:error, {:fs_root_overlaps, String.t(), atom(), :equal | :ancestor | :descendant}}
  def check_roots(roots, protected) do
    Enum.reduce_while(roots, :ok, fn root, :ok ->
      canon = canonical(root)

      case Enum.find_value(protected, &overlap(canon, &1)) do
        nil -> {:cont, :ok}
        {which, relation} -> {:halt, {:error, {:fs_root_overlaps, root, which, relation}}}
      end
    end)
  end

  defp overlap(root, {which, dir}) do
    dir = canonical(dir)

    cond do
      root == dir -> {which, :equal}
      under?(dir, root) -> {which, :ancestor}
      under?(root, dir) -> {which, :descendant}
      true -> nil
    end
  end

  @doc "The protected directories in force, named: the data directory and the secrets directory."
  @spec protected_dirs() :: [{atom(), String.t()}]
  def protected_dirs,
    do: [data_dir: Trinity.Paths.data_dir(), secrets_dir: Trinity.Paths.secrets_dir()]

  @doc "The roots configured (`config :trinity, :fs, roots`) and chosen in Settings, expanded."
  @spec configured_roots() :: [String.t()]
  def configured_roots do
    configured = Application.get_env(:trinity, :fs, []) |> Keyword.get(:roots, [])
    chosen = Trinity.Settings.get(:fs_roots)
    (configured ++ chosen) |> Enum.map(&Path.expand/1) |> Enum.uniq()
  end

  @doc """
  The boot check (AC2): every configured root against the data and secrets directories. Raises with
  the named reason, which stops the application before any child exists.
  """
  @spec verify_boot!() :: :ok
  def verify_boot! do
    case check_roots(configured_roots(), protected_dirs()) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Trinity refuses to boot: #{inspect(reason)}. A filesystem root must not be, contain " <>
                "or sit inside the data directory or the secrets directory; remove it from " <>
                "TRINITY_FS_ROOTS (config :trinity, :fs, roots) or from the folders in Settings."
    end
  end

  ## Scope

  @doc "What one call is judged against: the protected set, the inventory and the roots, taken now."
  @spec scope(String.t() | nil) :: scope()
  def scope(cwd) do
    data = canonical(Trinity.Paths.data_dir())
    secrets = canonical(Trinity.Paths.secrets_dir())
    protected_dirs = [data_dir: data, secrets_dir: secrets]

    roots =
      for root <- configured_roots(),
          canon = canonical(root),
          check_roots([canon], protected_dirs) == :ok,
          do: {root, canon}

    %{
      data_dir: data,
      secrets_dir: secrets,
      protected: Enum.map(protected_files(), &canonical/1),
      inventory: inventory(data, secrets),
      roots: roots,
      cwd: cwd && canonical(Path.expand(cwd)),
      allow_hard_links:
        Application.get_env(:trinity, :fs, []) |> Keyword.get(:allow_hard_links, false)
    }
  end

  @doc "The canonical roots in force: configured and chosen, less any that overlaps a protected directory."
  @spec roots() :: [String.t()]
  def roots, do: nil |> scope() |> Map.fetch!(:roots) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  # Files Trinity keeps that may sit outside both directories when configured there: the databases
  # and their journals, the keys directory, the MCP token and OAuth store.
  defp protected_files do
    dbs =
      for repo <- [Trinity.Repo, Trinity.Repo.Receipts],
          db = Application.get_env(:trinity, repo, [])[:database],
          is_binary(db),
          suffix <- ["", "-wal", "-shm", "-journal"],
          do: db <> suffix

    keys = List.wrap(Application.get_env(:trinity, :receipts, [])[:keys_dir])
    auth = Application.get_env(:trinity, :mcp_auth, [])
    dbs ++ keys ++ Enum.reject([auth[:token_path], auth[:store_dir]], &is_nil/1)
  end

  # Every (dev, ino) the guard refuses whatever path reaches it, with the rule a refusal names: the
  # two directories by their own names (so a bind mount of either is named for what it is), every
  # other inventoried inode as `protected_inode`.
  defp inventory(data, secrets) do
    trees = [secrets | protected_files()] ++ [Path.join(data, "keys")]

    entries =
      trees
      |> Enum.flat_map(&walk(&1, @inventory_cap))
      |> Map.new(&{&1, "protected_inode"})

    [{data, "data_dir"}, {secrets, "secrets_dir"}]
    |> Enum.reduce(entries, fn {dir, label}, acc ->
      case inode(dir) do
        nil -> acc
        key -> Map.put(acc, key, label)
      end
    end)
  end

  defp walk(path, budget) do
    case lstat(path) do
      {:ok, %{type: :directory} = info} ->
        children =
          case File.ls(path) do
            {:ok, names} -> names |> Enum.take(budget) |> Enum.map(&Path.join(path, &1))
            _ -> []
          end

        [key(info) | Enum.flat_map(children, &walk(&1, budget))]

      {:ok, info} ->
        [key(info)]

      _ ->
        []
    end
  end

  defp inode(path) do
    case lstat(path) do
      {:ok, info} -> key(info)
      _ -> nil
    end
  end

  defp key(%File.Stat{major_device: dev, inode: ino}), do: {dev, ino}

  ## Call time

  @doc """
  The verdict for `path` (relative to `cwd`) used as `mode`. Never raises; never opens the file.
  """
  @spec check(String.t(), String.t() | nil, mode(), scope() | nil) :: verdict()
  def check(path, cwd, mode, scope \\ nil) do
    scope = scope || scope(cwd)
    base = scope.cwd || canonical(File.cwd!())
    absolute = path |> Path.expand(base) |> unalias(scope.roots)
    verdict = %{blank(path) | canonical: absolute}

    with :ok <- refused_tree(absolute),
         {:ok, final} <- components(absolute, scope),
         :ok <- zone(absolute, scope),
         :ok <- final_kind(final, mode, scope),
         :ok <- denied_name(absolute) do
      root = matching_root(absolute, scope)
      decision = if root, do: :allow, else: :ask
      %{with_info(verdict, final) | root: root, decision: decision}
    else
      {:deny, rule, final} -> %{with_info(verdict, final) | rule: rule, decision: :deny}
      {:deny, rule} -> %{verdict | rule: rule, decision: :deny}
    end
  end

  defp blank(path),
    do: %{
      requested: path,
      canonical: nil,
      dev: nil,
      ino: nil,
      nlink: nil,
      type: nil,
      root: nil,
      rule: nil,
      decision: :deny
    }

  defp with_info(verdict, nil), do: verdict

  defp with_info(verdict, %File.Stat{} = info),
    do: %{
      verdict
      | dev: info.major_device,
        ino: info.inode,
        nlink: info.links,
        type: info.type
    }

  # A configured root reached through its own (symlinked) spelling is read as its canonical form:
  # roots are the operator's configuration, trusted as written.
  defp unalias(absolute, roots) do
    Enum.find_value(roots, absolute, fn {spelled, canon} ->
      cond do
        spelled == canon -> nil
        absolute == spelled -> canon
        under?(absolute, spelled) -> canon <> String.replace_prefix(absolute, spelled, "")
        true -> nil
      end
    end)
  end

  defp refused_tree(absolute) do
    if Enum.any?(@refused_trees, &under?(absolute, &1)),
      do: {:deny, "proc_or_dev"},
      else: :ok
  end

  # lstat on every existing component, from the top. A symlink anywhere is refused; an inventoried
  # inode anywhere is refused. Returns the final component's stat, or nil when it does not exist.
  defp components(absolute, scope) do
    [top | parts] = Path.split(absolute)
    walk_components(parts, top, nil, scope)
  end

  defp walk_components([], _dir, info, _scope), do: {:ok, info}

  defp walk_components([part | rest], dir, _info, scope) do
    path = Path.join(dir, part)

    case lstat(path) do
      {:ok, info} -> component(info, path, rest, scope)
      {:error, reason} when reason in [:enoent, :enotdir] -> {:ok, nil}
      {:error, _} -> {:deny, "unverifiable"}
    end
  end

  defp component(%File.Stat{type: :symlink} = info, _path, _rest, _scope),
    do: {:deny, "symlink", info}

  defp component(info, path, rest, scope) do
    case Map.fetch(scope.inventory, key(info)) do
      {:ok, rule} -> {:deny, rule, info}
      :error -> walk_components(rest, path, info, scope)
    end
  end

  defp zone(absolute, scope) do
    cond do
      under?(absolute, scope.data_dir) -> {:deny, "data_dir"}
      under?(absolute, scope.secrets_dir) -> {:deny, "secrets_dir"}
      Enum.any?(scope.protected, &under?(absolute, &1)) -> {:deny, "protected_path"}
      true -> :ok
    end
  end

  defp final_kind(nil, _mode, _scope), do: :ok

  defp final_kind(%File.Stat{type: :regular, links: n} = info, _mode, scope) when n > 1 do
    if scope.allow_hard_links, do: :ok, else: {:deny, "hard_link", info}
  end

  defp final_kind(%File.Stat{type: type}, _mode, _scope) when type in [:regular, :directory],
    do: :ok

  defp final_kind(%File.Stat{} = info, _mode, _scope), do: {:deny, "special_file", info}

  defp denied_name(absolute) do
    base = Path.basename(absolute)

    case Enum.find(@deny_list, &glob?(&1, base)) do
      nil -> :ok
      pattern -> {:deny, "deny_list:" <> pattern}
    end
  end

  defp glob?(pattern, name) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    Regex.match?(~r/\A#{regex}\z/, name)
  end

  defp matching_root(absolute, scope) do
    candidates = Enum.map(scope.roots, &elem(&1, 1)) ++ List.wrap(scope.cwd)

    candidates
    |> Enum.filter(&under?(absolute, &1))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  ## Open time

  @doc """
  Opens `path` for reading after `check/4`, `fstat`s the descriptor and refuses what the walk could
  not see; returns the bytes and the verdict. `opts`: `zones: false` for a caller with its own jail
  (`skill_file`), which keeps the inode, link-count, kind and deny-list checks and skips the
  directory and symlink ones (the jail resolved the path itself).
  """
  @spec read(String.t(), String.t() | nil, keyword()) ::
          {:ok, binary(), verdict()} | {:error, {:fs_denied, verdict()}} | {:error, term()}
  # sobelow_skip reason: Traversal.FileModule: this is the guard itself. The path has been through
  # check/4 (lexical expansion, no symlinks, no protected directory, the deny-list) before the open,
  # and the opened descriptor is checked against the inode inventory after it.
  @sobelow_skip ["Traversal.FileModule"]
  def read(path, cwd, opts \\ []) do
    scope = Keyword.get_lazy(opts, :scope, fn -> scope(cwd) end)

    verdict =
      if Keyword.get(opts, :zones, true),
        do: check(path, cwd, :read, scope),
        else: jailed(path, scope)

    with :ok <- allowed(verdict, opts),
         {:ok, io} <- :file.open(verdict.canonical, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(io, [{:time, :posix}]),
             :ok <- after_open(File.Stat.from_record(info), verdict, scope) do
          {:ok, read_all(io, []), verdict}
        end
      after
        :file.close(io)
      end
    end
    |> case do
      {:ok, _, _} = ok -> ok
      {:error, {:fs_denied, _}} = denied -> denied
      {:deny, rule} -> {:error, {:fs_denied, %{verdict | rule: rule, decision: :deny}}}
      {:error, reason} -> {:error, {:file, reason, verdict.canonical}}
    end
  end

  # Inside a jail the caller resolved (skill_file): the kind, link count and deny-list checks, on
  # the path as given.
  defp jailed(path, scope) do
    base = %{blank(path) | canonical: path}

    case lstat(path) do
      {:ok, info} ->
        v = with_info(base, info)

        with :ok <- not_inventoried(info, scope),
             :ok <- final_kind(info, :read, scope) |> strip(),
             :ok <- denied_name(path) do
          %{v | decision: :allow}
        else
          {:deny, rule} -> %{v | rule: rule, decision: :deny}
        end

      {:error, _} ->
        %{base | decision: :allow}
    end
  end

  defp not_inventoried(info, scope) do
    case Map.fetch(scope.inventory, key(info)) do
      {:ok, rule} -> {:deny, rule}
      :error -> :ok
    end
  end

  defp strip({:deny, rule, _info}), do: {:deny, rule}
  defp strip(other), do: other

  # A read the gate asked about and the owner allowed is an `:ask` verdict that is no longer a
  # question; only a denial stops it here.
  defp allowed(%{decision: :deny} = v, _opts), do: {:error, {:fs_denied, v}}
  defp allowed(_v, _opts), do: :ok

  defp after_open(%File.Stat{} = info, verdict, scope) do
    cond do
      Map.has_key?(scope.inventory, key(info)) ->
        {:deny, Map.fetch!(scope.inventory, key(info))}

      info.type != :regular ->
        {:deny, "special_file"}

      info.links > 1 and not scope.allow_hard_links ->
        {:deny, "hard_link"}

      verdict.ino != nil and {verdict.dev, verdict.ino} != key(info) ->
        {:deny, "changed_during_open"}

      true ->
        :ok
    end
  end

  defp read_all(io, acc) do
    case :file.read(io, 1_048_576) do
      {:ok, chunk} -> read_all(io, [acc | chunk])
      :eof -> IO.iodata_to_binary(acc)
      {:error, _} -> IO.iodata_to_binary(acc)
    end
  end

  ## Receipts

  @doc """
  The fields a receipt carries for one fs decision (AC6): tool, requested path, canonical path,
  `(dev, ino)`, the root matched or none, the deny rule matched, nlink, the decision, the core policy
  hash, the principal and the turn id. Never the file's contents.
  """
  @spec receipt_fields(verdict(), String.t(), map()) :: map()
  def receipt_fields(verdict, tool, ctx) do
    %{
      "tool" => tool,
      "requested_path" => verdict.requested,
      "canonical_path" => verdict.canonical,
      "dev" => verdict.dev,
      "ino" => verdict.ino,
      "root" => verdict.root,
      "deny_rule" => verdict.rule,
      "nlink" => verdict.nlink,
      "decision" => Atom.to_string(verdict.decision),
      "policy_hash" => policy_hash(),
      "principal" => principal(ctx),
      "turn_id" => Map.get(ctx, :turn_id)
    }
  end

  defp principal(%{principal: %{} = p}) when map_size(p) > 0, do: p
  defp principal(%{caller: caller}) when is_binary(caller), do: %{"caller" => caller}
  defp principal(%{caller: nil}), do: nil
  defp principal(%{caller: caller}), do: %{"caller" => inspect(caller)}
  defp principal(_), do: nil

  # The core policy hash is a digest over object code that does not change while the VM runs.
  defp policy_hash do
    case :persistent_term.get({__MODULE__, :policy_hash}, nil) do
      nil ->
        hash = Trinity.CorePolicy.hash()
        :persistent_term.put({__MODULE__, :policy_hash}, hash)
        hash

      hash ->
        hash
    end
  end

  ## Paths

  @doc "True when `path` is `root` or under it."
  @spec under?(String.t(), String.t()) :: boolean()
  def under?(path, root) do
    # A filesystem root ("/", "C:/") already ends in its separator.
    if String.ends_with?(root, "/"),
      do: String.starts_with?(path, root),
      else: path == root or String.starts_with?(path, root <> "/")
  end

  @doc """
  The canonical form of a trusted path (a root, a protected directory, the working directory):
  expanded, with every symlink on its longest existing prefix resolved. Never used on a tool's
  argument, which is refused at its first symlink instead.
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(path) do
    absolute = Path.expand(path)
    {existing, rest} = split_existing(absolute, [])
    Path.join([resolve_links(existing, 40) | rest])
  end

  defp split_existing("/", rest), do: {"/", rest}

  defp split_existing(path, rest) do
    case lstat(path) do
      {:ok, _} -> {path, rest}
      _ -> split_existing(Path.dirname(path), [Path.basename(path) | rest])
    end
  end

  defp resolve_links(path, 0), do: path

  defp resolve_links(path, hops) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        target |> List.to_string() |> Path.expand(Path.dirname(path)) |> resolve_links(hops - 1)

      _ ->
        parent = Path.dirname(path)

        if parent == path,
          do: path,
          else: Path.join(resolve_links(parent, hops), Path.basename(path))
    end
  end

  defp lstat(path), do: File.lstat(path, time: :posix)
end
