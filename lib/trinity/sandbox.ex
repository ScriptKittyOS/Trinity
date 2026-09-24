# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox do
  @moduledoc """
  Lua in the BEAM, under limits the VM enforces (slice 110).

  Skills that can execute need a real programming surface. This gives the agent one without giving
  it the machine: `luerl` interprets Lua inside this node, so there is no operating system process,
  no filesystem handle and no network socket unless the host API hands one over, and every effect
  still passes the permission gate as the calling session.

  ## The limits, and which of them actually bind

  Measured against `luerl` 1.5.1 before this module was written (slice NOTES F1), because the
  library's own limits are not all what their names suggest:

  * **Heap** is the hard one. The runner is spawned with `max_heap_size`, which the VM enforces
    itself and which kills the process the moment it is exceeded. A memory bomb dies here.
  * **Wall clock** is real: this module waits on a monitor with a timeout and kills what is still
    running.
  * **Reductions are coarse, and this module says so rather than implying otherwise.**
    `luerl_sandbox` polls `process_info(:reductions)` with a 100 ms sleep between checks, so the
    first observation of a tight loop already sees tens of millions and no smaller bound can hold.
    Measured: caps of 1,000 and of 1,000,000 both terminated at 20 to 34 million reductions and
    101 ms. The reduction count is therefore reported as a **statistic**, and the bound that stops
    a runaway script is time.

  This module runs the interpreter itself rather than calling `luerl_sandbox.run/3`, for those
  reasons: it needs `max_heap_size` on the runner, a timeout it controls, and the reductions actually
  used on the way out. It still uses `luerl_sandbox.init/0` for the globals removal, which is the
  part of that module worth having.

  ## What is removed, and what survives

  `luerl_sandbox.init/0` removes `io` and `file` wholesale, `package`, `require`, `dofile`, `load`,
  `loadfile` and `loadstring`, and from `os` the members `execute`, `exit`, `getenv`, `remove`,
  `rename` and `tmpname`.

  **`os` itself survives**, so `os.time`, `os.date` and `os.clock` remain callable. None can reach
  the machine, but all three are non-deterministic, which matters when a script's output can end up
  in a receipt. `docs/sandbox.md` names them rather than leaving them to be found.
  """
  # `Trinity.Tools` and `Trinity.Effects` are dependencies because the host API's `trinity.tool`
  # goes through the ordinary executor rather than around it. That is the point of the seam:
  # a call made from Lua is decided by the same gate and receipted the same way, so there is no
  # second door to audit.
  use Boundary,
    top_level?: true,
    # `Trinity` alone: `Tools`, `Tools.Context` and `Effects.Runner` are exports of that boundary,
    # so naming them here as well is both unnecessary and rejected, since they are sub-boundaries
    # rather than siblings of this one.
    deps: [Trinity],
    exports: [Runner, Host, Tool]

  alias Trinity.Sandbox.Runner

  @type stats :: %{
          reductions: non_neg_integer(),
          time_ms: non_neg_integer(),
          heap_words: non_neg_integer()
        }
  @type outcome :: {:ok, term(), stats()} | {:error, term()}

  # A tight Lua loop burns about 250,000 reductions per millisecond on the machine this was measured
  # on, so a second is a generous ceiling for a script that is doing arithmetic and a short one for
  # a script that is stuck.
  @default_time_ms 1_000

  # Words, not bytes. 8 MB on a 64-bit VM, which is far above anything a skill script should need
  # and far below anything that threatens the node.
  @default_heap_words 1_000_000

  @doc "The default limits, as a keyword list, so a caller can read them rather than guess."
  @spec defaults() :: keyword()
  def defaults, do: [max_time_ms: @default_time_ms, max_heap_words: @default_heap_words]

  @doc """
  Runs `code` and returns its value with the statistics of the run.

  Options: `max_time_ms`, `max_heap_words`. A refusal is always a named tuple and never an exit in
  the caller: a script that runs away is the sandbox working, not an error the caller should die of.
  """
  @spec run(String.t(), keyword()) :: outcome()
  def run(code, opts \\ []) when is_binary(code) do
    Runner.run(code, Keyword.merge(defaults(), opts))
  end
end
