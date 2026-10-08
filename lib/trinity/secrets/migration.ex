# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Secrets.Migration do
  @moduledoc """
  Moves the secrets an earlier release kept under the data directory into the secrets directory
  (slice 135, AC4), once per boot, before anything reads them.

  | Before (under the data directory) | After (under `Trinity.Paths.secrets_dir/0`) |
  |---|---|
  | `keys/` (the receipt key, its registry, the MCP state key, the device id, the MCP authorization server's keys) | `keys/` |
  | `mcp-server-token` (the MCP bearer token) | `mcp-server-token` |
  | `secrets/oauth/` (the MCP client's OAuth tokens) | `oauth/` |

  A location the operator configured explicitly (`config :trinity, :receipts, keys_dir`, or
  `:mcp_auth`'s `token_path` and `store_dir`) is the operator's and is not touched.

  **Moved, not copied and not re-keyed.** Each file is renamed (copied and then removed when the two
  directories are on different filesystems), so the receipt key keeps its key id and the registry
  moves whole: every receipt signed before the move still verifies against it. A file already present
  at the destination is never overwritten; the source is left where it is and reported as a conflict
  (it stays unreachable to every tool, being under the data directory).

  **Modes.** The directories are 0700. A file whose writer never rewrites it in place (key material:
  `*.key`, `*.jwk.json`, the bearer token) is 0400; the registry and the OAuth store, which their
  writers replace or rewrite, stay 0600 (slice 135 NOTES, D3).

  **Receipted.** The report is kept for the boot receipt (`Trinity.Effects.Boot`), which names it in
  its signed subject, and logged. It names files and directories, never their contents.
  """

  require Logger

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @key {__MODULE__, :report}

  @typedoc "What one boot moved; `nil` when nothing was there to move."
  @type report :: %{String.t() => term()} | nil

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  @doc """
  Runs the move inside the supervisor's start, records the report, and starts nothing. Off when
  `config :trinity, Trinity.Secrets.Migration, enabled: false`, which the suite sets: the suite runs
  against the machine's own data directory, and a test boot must never move the machine's files
  (slice 135 NOTES records the run that did, before this switch existed).
  """
  @spec start_link(term()) :: :ignore
  def start_link(_arg) do
    if Application.get_env(:trinity, __MODULE__, []) |> Keyword.get(:enabled, true),
      do: :persistent_term.put(@key, run())

    :ignore
  end

  @doc "The report of this boot's move, or `nil` when there was nothing to move."
  @spec report() :: report()
  def report, do: :persistent_term.get(@key, nil)

  @doc """
  Moves what is there to move and returns the report (`nil` when nothing was). `opts` override the
  directories, for a test: `data_dir:`, `secrets_dir:`.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    data = Keyword.get_lazy(opts, :data_dir, &Trinity.Paths.data_dir/0)
    secrets = Keyword.get_lazy(opts, :secrets_dir, &Trinity.Paths.secrets_dir/0)
    receipts = Application.get_env(:trinity, :receipts, [])
    auth = Application.get_env(:trinity, :mcp_auth, [])

    moves =
      [
        {is_nil(receipts[:keys_dir]), Path.join(data, "keys"), Path.join(secrets, "keys")},
        {is_nil(auth[:token_path]), Path.join(data, "mcp-server-token"),
         Path.join(secrets, "mcp-server-token")},
        {is_nil(auth[:store_dir]), Path.join([data, "secrets", "oauth"]),
         Path.join(secrets, "oauth")}
      ]
      |> Enum.filter(fn {ours?, from, _to} -> ours? and File.exists?(from) end)

    case moves do
      [] -> nil
      moves -> move_all(moves, data, secrets)
    end
  end

  defp move_all(moves, data, secrets) do
    ensure_dir!(secrets)
    results = Enum.map(moves, fn {_, from, to} -> {from, to, move(from, to)} end)
    _ = File.rmdir(Path.join(data, "secrets"))

    keys_from = Path.join(data, "keys")

    report = %{
      "from" => data,
      "to" => Path.join(secrets, "keys"),
      "files" =>
        for({^keys_from, _, %{moved: moved}} <- results, do: moved)
        |> List.flatten()
        |> Enum.sort(),
      "moved" => for({from, to, %{moved: [_ | _]}} <- results, do: %{"from" => from, "to" => to}),
      "conflicts" =>
        for({_from, _to, %{conflicts: c}} <- results, path <- c, do: path) |> Enum.sort()
    }

    Logger.warning(
      "secrets: moved out of the data directory into #{secrets}: " <>
        inspect(Map.take(report, ["moved", "files", "conflicts"]))
    )

    report
  end

  # A directory: every entry moved into the destination directory, the source removed when it is
  # left empty. A file: moved when the destination is free.
  # sobelow_skip reason: Traversal.FileModule: every path is the data directory or the secrets
  # directory plus a constant, or an entry a listing of one of them returned; never request input.
  @sobelow_skip ["Traversal.FileModule"]
  defp move(from, to) do
    if File.dir?(from) do
      ensure_dir!(to)

      acc =
        from
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reduce(%{moved: [], conflicts: []}, &move_entry(&1, from, to, &2))

      _ = File.rmdir(from)
      %{moved: Enum.reverse(acc.moved), conflicts: Enum.reverse(acc.conflicts)}
    else
      ensure_dir!(Path.dirname(to))

      case move_file(from, to) do
        :ok -> %{moved: [Path.basename(from)], conflicts: []}
        {:conflict, path} -> %{moved: [], conflicts: [path]}
      end
    end
  end

  defp move_entry(name, from, to, acc) do
    case move_file(Path.join(from, name), Path.join(to, name)) do
      :ok -> %{acc | moved: [name | acc.moved]}
      {:conflict, path} -> %{acc | conflicts: [path | acc.conflicts]}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: as move/2.
  @sobelow_skip ["Traversal.FileModule"]
  # A rename that fails for any reason but a cross-device move raises, which stops the boot with
  # the reason: a signer that found no key where the registry says one is would make a new one, and
  # a split registry is worse than a refused start.
  defp move_file(from, to) do
    if File.exists?(to) do
      {:conflict, from}
    else
      case File.rename(from, to) do
        :ok -> :ok
        {:error, :exdev} -> copy_then_remove(from, to)
        {:error, reason} -> raise File.RenameError, source: from, destination: to, reason: reason
      end

      protect(to)
      :ok
    end
  end

  # sobelow_skip reason: Traversal.FileModule: as move/2.
  @sobelow_skip ["Traversal.FileModule"]
  defp copy_then_remove(from, to) do
    {:ok, _} = File.cp_r(from, to)
    {:ok, _} = File.rm_rf(from)
    :ok
  end

  # sobelow_skip reason: Traversal.FileModule: as move/2.
  @sobelow_skip ["Traversal.FileModule"]
  defp protect(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        File.chmod!(path, 0o700)
        path |> File.ls!() |> Enum.each(&protect(Path.join(path, &1)))

      {:ok, %{type: :regular}} ->
        File.chmod!(path, if(read_only?(path), do: 0o400, else: 0o600))

      _ ->
        :ok
    end
  end

  # Key material whose writer only ever creates it (a rotation writes a new file and renames).
  defp read_only?(path) do
    name = Path.basename(path)

    String.ends_with?(name, ".key") or String.ends_with?(name, ".jwk.json") or
      name == "mcp-server-token"
  end

  # sobelow_skip reason: Traversal.FileModule: as move/2.
  @sobelow_skip ["Traversal.FileModule"]
  defp ensure_dir!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
  end
end
