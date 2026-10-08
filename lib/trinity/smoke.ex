# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Smoke do
  @moduledoc """
  The `--smoke` boot path: start, prove the endpoint is listening, print the port, stop.

  A packaged binary that opens a window cannot be checked from a terminal, and the owner has
  one machine with no desktop session on it. `--smoke` is the half of the desktop app that a
  command can answer: the release boots, Bandit binds a real port on the loopback, the port is
  printed so `curl` can be pointed at it, and **the process exits by itself**. Slice 001 AC7
  reads `ps -eo pid,ppid,comm` either side of that exit and asserts nothing survives it.

  This module is packaging, not domain code. It starts nothing of its own and adds no
  behaviour to the app; it observes the endpoint the supervision tree already started.

  ## Its own boundary

  `Trinity` declares `deps: []`, so nothing inside it may call `TrinityWeb`. Smoke has to ask
  the endpoint what port it got, so it is its own top-level boundary alongside
  `Trinity.Application`, for the same reason that module is: it is the boot path, not the core.

  ## Why it stops the OS process and not the application

  `System.halt/1` ends the VM. `Application.stop/1` would leave the Burrito wrapper's process
  tree standing, and a wrapper still running after the app it wraps has finished is precisely
  the leaked sidecar AC7 looks for. The smoke path therefore ends the process it was given,
  which is the only exit a `ps` on the outside can see.
  """

  use Boundary, top_level?: true, deps: [Trinity, TrinityWeb], exports: []

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @flag "--smoke"

  @type halt_fun :: (non_neg_integer() -> any())
  @type say_fun :: (String.t() -> any())

  @doc """
  The arguments this OS process was launched with, under Burrito or under Mix.

  `:init.get_plain_arguments/0` is what `Burrito.Util.Args.get_arguments/0` reads, and reading
  it directly means `config/runtime.exs` can ask the same question at boot without any
  application being loaded yet.
  """
  @spec argv() :: [String.t()]
  def argv, do: Enum.map(:init.get_plain_arguments(), &to_string/1)

  @doc """
  Whether the smoke run was asked for: `#{@flag}` among the arguments, or `TRINITY_SMOKE=1` in
  the environment. The variable is the form the package workflow uses since slice 032:
  `Kernel.CLI` reads the same plain arguments once the application has started and treats
  `#{@flag}` as a file to run ("No file named --smoke", exit 1), and the Task that prints the
  lines and halts wins that race only sometimes (package run 35608084951, macOS: exit 1
  between the fourth line and the fifth). An environment variable is nothing for the CLI to
  read.
  """
  @spec requested?([String.t()]) :: boolean()
  def requested?(args), do: @flag in args or System.get_env("TRINITY_SMOKE") == "1"

  @doc """
  The line printed for the caller to parse. One key=value pair, no prose around it, so a shell
  can take it with `cut -d= -f2` and not a regex over a sentence.
  """
  @spec port_line(:inet.port_number()) :: String.t()
  def port_line(port), do: "TRINITY_SMOKE_PORT=#{port}"

  @doc """
  The second line (slice 013): whether the markdown renderer's NIF loaded and rendered in this
  binary. A packaged build whose NIF fails to load still boots and serves, showing escaped
  text instead of markdown (NOTES.md finding 13), so booting proves nothing about it; this
  does. `ok` or `failed:<reason>`, one line, no prose.
  """
  @spec markdown_line() :: String.t()
  def markdown_line do
    case MDEx.to_html("**smoke**", render: [unsafe: false]) do
      {:ok, html} ->
        if html =~ "<strong>smoke</strong>",
          do: "TRINITY_SMOKE_MARKDOWN=ok",
          else: "TRINITY_SMOKE_MARKDOWN=failed:#{inspect(html)}"

      {:error, reason} ->
        "TRINITY_SMOKE_MARKDOWN=failed:#{inspect(reason)}"
    end
  end

  @doc """
  The third line (slice 032): whether the EXLA NIF loaded in this binary and ran one
  operation. Informative, not binding: a bundle whose XLA library does not load (Burrito's
  musl ERTS against a glibc `.so`, NOTES finding 13's shape) still boots with the semantic
  tier off, and AC7 asks that the failure be recorded by name. `ok` or `failed:<reason>`.
  """
  @spec exla_line() :: String.t()
  def exla_line do
    if Code.ensure_loaded?(EXLA) and Trinity.Memory.Embedders.Bumblebee.exla() == :ok do
      try do
        t = Nx.tensor([1.0, 2.0], backend: EXLA.Backend)
        [3.0] = Nx.to_flat_list(Nx.sum(t))
        "TRINITY_SMOKE_EXLA=ok"
      rescue
        e -> "TRINITY_SMOKE_EXLA=failed:#{inspect(Exception.message(e) |> String.slice(0, 200))}"
      catch
        kind, reason ->
          "TRINITY_SMOKE_EXLA=failed:#{inspect({kind, reason}) |> String.slice(0, 200)}"
      end
    else
      "TRINITY_SMOKE_EXLA=failed:#{inspect(Trinity.Memory.Embedders.Bumblebee.exla()) |> String.slice(0, 200)}"
    end
  end

  @doc """
  The fourth line (slice 032, AC7): a fake-vector search inside this binary through the
  vector store in force, on the database the binary opened, rolled back. Three rows of the
  suite's deterministic vectors, the nearest expected first; `ok:<store>` or
  `failed:<reason>`. Binding: exit 4 when it fails. The tier's own status follows as the
  fifth line, informative (`on`, or the reason it is off on this machine).
  """
  @spec vec_line() :: String.t()
  def vec_line do
    case Trinity.Memory.Semantic.smoke() do
      {:ok, store} -> "TRINITY_SMOKE_VEC=ok:#{inspect(store)}"
      {:error, reason} -> "TRINITY_SMOKE_VEC=failed:#{inspect(reason) |> String.slice(0, 200)}"
    end
  end

  @doc "The fifth line: the semantic tier's status in this binary, informative."
  @spec semantic_line() :: String.t()
  def semantic_line do
    case Trinity.Memory.Semantic.status() do
      :on -> "TRINITY_SMOKE_SEMANTIC=on"
      {:off, reason} -> "TRINITY_SMOKE_SEMANTIC=off:#{inspect(reason) |> String.slice(0, 200)}"
    end
  end

  @doc """
  Slice 100, AC9: SQLite's FTS5 in this binary. Slice 031's session search is an FTS5 table, and
  a SQLite built without it boots and serves and fails the first search. An in-memory database,
  a virtual table, one row, one `MATCH`. Binding: exit 5. `ok` or `failed:<reason>`.
  """
  @spec fts5_line() :: String.t()
  def fts5_line do
    alias Exqlite.Sqlite3

    with {:ok, conn} <- Sqlite3.open(":memory:"),
         :ok <- Sqlite3.execute(conn, "CREATE VIRTUAL TABLE smoke USING fts5(body)"),
         :ok <- Sqlite3.execute(conn, "INSERT INTO smoke(body) VALUES ('packaged binary')"),
         {:ok, stmt} <-
           Sqlite3.prepare(conn, "SELECT count(*) FROM smoke WHERE smoke MATCH 'binary'"),
         {:row, [1]} <- Sqlite3.step(conn, stmt),
         :ok <- Sqlite3.release(conn, stmt),
         :ok <- Sqlite3.close(conn) do
      "TRINITY_SMOKE_FTS5=ok"
    else
      other -> "TRINITY_SMOKE_FTS5=failed:#{inspect(other) |> String.slice(0, 200)}"
    end
  end

  @doc """
  Slice 100, AC9: the file watcher the skills registry uses, measured in this binary: a watcher on
  a fresh directory with the registry's own options (`Trinity.Skills.Registry.watcher_options/0`),
  one file written, the event awaited. `ok:<backend>` when the native backend (or the configured
  one) delivered it; `fallback:fs_poll:<why the native one did not>` when only polling did, which
  is the registry's documented fallback and still exits 0 (slice 040: the reindex button and
  `mix trinity.skills.reindex` work either way); `failed:<reason>` when neither did. Informative.
  """
  @spec watcher_line() :: String.t()
  def watcher_line do
    opts = Trinity.Skills.Registry.watcher_options()
    native = Keyword.get(opts, :backend, native_backend())

    case watch_once(opts) do
      :ok ->
        "TRINITY_SMOKE_WATCHER=ok:#{native}"

      {:error, why} when native != :fs_poll ->
        case watch_once(backend: :fs_poll, interval: 200) do
          :ok ->
            "TRINITY_SMOKE_WATCHER=fallback:fs_poll:#{inspect(why) |> String.slice(0, 120)}"

          {:error, poll} ->
            "TRINITY_SMOKE_WATCHER=failed:#{inspect({why, poll}) |> String.slice(0, 200)}"
        end

      {:error, why} ->
        "TRINITY_SMOKE_WATCHER=failed:#{inspect(why) |> String.slice(0, 200)}"
    end
  end

  defp native_backend do
    case :os.type() do
      {:unix, :darwin} -> :fs_mac
      {:win32, _} -> :fs_windows
      _ -> :fs_inotify
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the directory is the system temporary directory
  # plus a constant prefix and a unique integer, and the file in it a constant name; nothing comes
  # from a request.
  @sobelow_skip ["Traversal.FileModule"]
  defp watch_once(opts) do
    dir =
      Path.join(System.tmp_dir!(), "trinity-smoke-watch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    try do
      case FileSystem.start_link([dirs: [dir]] ++ opts) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          # A native backend needs a moment to place its watch before the write it should see.
          Process.sleep(300)
          File.write!(Path.join(dir, "probe.txt"), "smoke")

          result =
            receive do
              {:file_event, ^pid, {_path, _events}} -> :ok
              {:file_event, ^pid, :stop} -> {:error, :watcher_stopped}
            after
              4_000 -> {:error, :no_event}
            end

          Process.unlink(pid)
          Process.exit(pid, :shutdown)
          result

        other ->
          {:error, other}
      end
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  Slice 100, AC9: the local embedder's model cache resolves to a directory this binary can write
  (`Trinity.Memory.Embedders.Bumblebee.cache_dir/0`: `BUMBLEBEE_CACHE_DIR`, the configured one, or
  the data directory's `models/`). Binding: exit 6. `ok:<dir>` or `failed:<reason>`.
  """
  # sobelow_skip reason: Traversal.FileModule: the directory is the model cache in force
  # (`BUMBLEBEE_CACHE_DIR`, configuration, or the data directory's `models/`), never request input.
  @sobelow_skip ["Traversal.FileModule"]
  @spec model_cache_line() :: String.t()
  def model_cache_line do
    dir = Trinity.Memory.Embedders.Bumblebee.cache_dir()

    # Created if absent, as the first download would create it; otherwise only looked at, so a
    # check run against an existing installation writes nothing into it.
    with :ok <- File.mkdir_p(dir),
         {:ok, %File.Stat{type: :directory, access: access}} <- File.stat(dir),
         true <- access in [:read_write, :write] || {:error, {:not_writable, access}} do
      "TRINITY_SMOKE_MODEL_CACHE=ok:#{dir}"
    else
      {:ok, %File.Stat{type: type}} ->
        "TRINITY_SMOKE_MODEL_CACHE=failed:#{inspect({:not_a_directory, type})}"

      {:error, reason} ->
        "TRINITY_SMOKE_MODEL_CACHE=failed:#{inspect(reason)}"
    end
  end

  @doc """
  Runs the smoke check: report the listening port, then stop the OS process.

  `say` and `halt` are injected so the whole path is exercisable from a test without ending
  the test runner's own OS process.
  """
  @spec run(say_fun(), halt_fun(), String.t(), [String.t()]) :: any()
  def run(say \\ &IO.puts/1, halt \\ &System.halt/1, markdown \\ markdown_line(), rest \\ nil) do
    {:ok, {_ip, port}} = TrinityWeb.Endpoint.server_info(:http)
    say.(port_line(port))
    say.(markdown)
    lines = rest || probe_lines()
    Enum.each(lines, say)
    line = fn key -> Enum.find(lines, "", &String.starts_with?(&1, "TRINITY_SMOKE_#{key}=")) end

    halt.(
      cond do
        markdown != "TRINITY_SMOKE_MARKDOWN=ok" -> 3
        not String.starts_with?(line.("VEC"), "TRINITY_SMOKE_VEC=ok:") -> 4
        line.("FTS5") != "TRINITY_SMOKE_FTS5=ok" -> 5
        not String.starts_with?(line.("MODEL_CACHE"), "TRINITY_SMOKE_MODEL_CACHE=ok:") -> 6
        true -> 0
      end
    )
  end

  @doc """
  The supervised children the smoke path adds: one `Task`, or none.

  Appended **after** `TrinityWeb.Endpoint` in `Trinity.Application`, because the task asks the
  endpoint which port it bound and a child cannot ask that of a sibling that has not started.

  It is a supervised child rather than a `Task.start/1` because docs/03's engineering rules say
  supervise everything and no bare spawn, and because running it inside `start/2` would halt
  the VM from within the OTP boot sequence: a boot crash rather than a clean exit. `ps`
  cannot tell those apart from the outside; the exit code can, and AC7 reads both.
  """
  #
  # The markdown line is computed here, inside `Trinity.Application.start/2`, not in the Task:
  # `Kernel.CLI` reads the same plain arguments once the application has started and treats
  # `--smoke` as a file to run ("No file named --smoke", exit 1), so the Task wins only by
  # halting at once. Measured at slice 013 when a few milliseconds of rendering inside the
  # Task lost that race on the first packaged run.
  @spec children([String.t()]) :: [Supervisor.child_spec() | {module(), term()}]
  def children(args) do
    if requested?(args) do
      markdown = markdown_line()
      # The 032 lines were computed by `probe/1`, a child placed after the Repo, the memory
      # supervisor and the sessions (package run 35600216451: computed here, before the
      # tree, the vector check found no Repo); the Task only reads them.
      [{Task, fn -> run(&IO.puts/1, &System.halt/1, markdown, probed()) end}]
    else
      []
    end
  end

  @doc """
  The child that computes the 032 lines (slice 032): placed in `Trinity.Application` just
  before the endpoint, so the Repo, the memory supervisor and the sessions are up. Its
  `start_link/1` does the work synchronously and answers `:ignore`, so the supervisor waits
  for it and starts no process; `children/1`'s Task reads the result.
  """
  @spec probe([String.t()]) :: [Supervisor.child_spec()]
  def probe(args) do
    if requested?(args), do: [Trinity.Smoke.Probe], else: []
  end

  @doc false
  @spec probed() :: [String.t()]
  def probed do
    :persistent_term.get({__MODULE__, :probed}, [
      "TRINITY_SMOKE_EXLA=failed:not_probed",
      "TRINITY_SMOKE_VEC=failed:not_probed",
      "TRINITY_SMOKE_SEMANTIC=off:not_probed",
      "TRINITY_SMOKE_FTS5=failed:not_probed",
      "TRINITY_SMOKE_WATCHER=failed:not_probed",
      "TRINITY_SMOKE_MODEL_CACHE=failed:not_probed"
    ])
  end

  @doc """
  The lines after the markdown one, in the order they are printed: slice 032's three, then slice
  100's three (AC9). Computed by `Probe`, inside the tree, where the Repo is up.
  """
  @spec probe_lines() :: [String.t()]
  def probe_lines do
    [
      exla_line(),
      vec_line(),
      semantic_line(),
      fts5_line(),
      watcher_line(),
      model_cache_line()
    ]
  end

  defmodule Probe do
    @moduledoc false
    use Boundary, top_level?: true, deps: [Trinity, Trinity.Smoke]

    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

    def start_link do
      :persistent_term.put({Trinity.Smoke, :probed}, Trinity.Smoke.probe_lines())
      :ignore
    end
  end
end
