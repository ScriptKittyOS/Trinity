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

  ## FIRST PASS — the red for slice 001 line 5

  `run/2` below reports the port and returns. It never calls `halt`, so a binary launched with
  `--smoke` prints its port and then keeps serving forever. `test/smoke_test.exs` fails on
  exactly that, which is the property line 5 exists to establish.
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

  @doc "Whether `#{@flag}` was passed."
  @spec requested?([String.t()]) :: boolean()
  def requested?(args), do: @flag in args

  @doc """
  The line printed for the caller to parse. One key=value pair, no prose around it, so a shell
  can take it with `cut -d= -f2` and not a regex over a sentence.
  """
  @spec port_line(:inet.port_number()) :: String.t()
  def port_line(port), do: "TRINITY_SMOKE_PORT=#{port}"

  @doc """
  Runs the smoke check: report the listening port, then stop the OS process.

  `say` and `halt` are injected so the whole path is exercisable from a test without ending
  the test runner's own OS process.
  """
  @spec run(say_fun(), halt_fun()) :: any()
  def run(say \\ &IO.puts/1, _halt \\ &System.halt/1) do
    {:ok, {_ip, port}} = TrinityWeb.Endpoint.server_info(:http)
    say.(port_line(port))
  end
end
