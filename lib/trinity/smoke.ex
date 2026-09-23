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
  Runs the smoke check: report the listening port, then stop the OS process.

  `say` and `halt` are injected so the whole path is exercisable from a test without ending
  the test runner's own OS process.
  """
  @spec run(say_fun(), halt_fun(), String.t(), [String.t()]) :: any()
  def run(say \\ &IO.puts/1, halt \\ &System.halt/1, markdown \\ markdown_line(), rest \\ nil) do
    {:ok, {_ip, port}} = TrinityWeb.Endpoint.server_info(:http)
    say.(port_line(port))
    say.(markdown)
    [exla, vec, semantic] = rest || [exla_line(), vec_line(), semantic_line()]
    say.(exla)
    say.(vec)
    say.(semantic)

    halt.(
      cond do
        markdown != "TRINITY_SMOKE_MARKDOWN=ok" -> 3
        not String.starts_with?(vec, "TRINITY_SMOKE_VEC=ok:") -> 4
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
      "TRINITY_SMOKE_SEMANTIC=off:not_probed"
    ])
  end

  defmodule Probe do
    @moduledoc false
    use Boundary, top_level?: true, deps: [Trinity, Trinity.Smoke]

    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

    def start_link do
      lines = [Trinity.Smoke.exla_line(), Trinity.Smoke.vec_line(), Trinity.Smoke.semantic_line()]
      :persistent_term.put({Trinity.Smoke, :probed}, lines)
      :ignore
    end
  end
end
