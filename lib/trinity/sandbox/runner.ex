# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.Runner do
  @moduledoc """
  One Lua evaluation, in one process, under limits the VM enforces (slice 110).

  The runner sets `max_heap_size` on itself so the VM kills it without this module being involved,
  and monitored with a timeout so a script that is merely slow is killed by the caller. Both paths
  return a named tuple; neither propagates into the caller, because a runaway script is the sandbox
  doing its job and the caller should learn that as a value.
  """
  @moduledoc since: "slice 110"

  @type outcome :: Trinity.Sandbox.outcome()

  alias Trinity.Sandbox.Host
  alias Trinity.Tools.Context

  @doc "Evaluates `code` under `opts`, which are already merged with the defaults."
  @spec run(String.t(), keyword()) :: outcome()
  def run(code, opts) do
    max_time = Keyword.fetch!(opts, :max_time_ms)
    heap = Keyword.fetch!(opts, :max_heap_words)
    me = self()
    started = System.monotonic_time(:millisecond)

    body = fn ->
      Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
      result = evaluate(code, Keyword.get(opts, :context))

      # Read the count **inside** the runner, before it exits. The first version read it from the
      # caller after the reply arrived, by which time the process was almost always gone and
      # `Process.info/2` returned nil, so every run reported zero reductions. A statistic that is
      # always zero is worse than no statistic, because it looks like a measurement.
      {:reductions, used} = Process.info(self(), :reductions)
      send(me, {self(), result, used, Host.log(), Host.result()})
    end

    # `start_child/2` rather than `async_nolink/2` because the cap has to be a value, not an exit:
    # a `max_children` refusal is the pool working, and a caller asking for one run too many should
    # be told so rather than killed for it.
    case Task.Supervisor.start_child(Trinity.Sandbox.TaskSupervisor, body) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        await(pid, ref, max_time, started)

      {:error, :max_children} ->
        {:error, {:pool_full, concurrency()}}

      {:error, reason} ->
        {:error, {:not_started, reason}}
    end
  end

  @doc "How many runs may be in flight at once."
  @spec concurrency() :: pos_integer()
  def concurrency do
    Application.get_env(:trinity, :sandbox, [])
    |> Keyword.get(:max_concurrency, 8)
  end

  defp evaluate(code, context) do
    Host.reset()
    state = install(:luerl_sandbox.init(), context)

    try do
      {:ok, values, _new_state} = :luerl.do(code, state)
      {:ok, values}
    catch
      :error, {:lua_error, reason, _st} -> {:lua_error, reason}
      :error, reason -> {:lua_error, reason}
      kind, reason -> {:crashed, {kind, reason}}
    end
  end

  # A run with no context gets the interpreter and no host surface. That is the right default for a
  # pure computation, and it means a caller has to say whose authority a script runs under before it
  # can reach a tool at all.
  defp install(state, nil), do: state

  defp install(state, %Context{} = ctx) do
    case Host.install(state, ctx) do
      {:ok, state} -> state
      {:error, _} -> state
    end
  end

  defp await(pid, ref, max_time, started) do
    receive do
      {^pid, result, reductions, log, declared} ->
        Process.demonitor(ref, [:flush])
        finish(result, reductions, started, log, declared)

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        # The VM's own kill, which on this path means `max_heap_size` was exceeded. It is reported
        # by name because "killed" alone would leave a reader guessing which limit bound.
        {:error, :heap_exceeded}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:runner_died, reason}}
    after
      max_time ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        flush(pid)
        {:error, {:timeout, max_time}}
    end
  end

  defp finish({:ok, values}, reductions, started, log, declared) do
    {:ok, declared || values, stats(reductions, started, log)}
  end

  defp finish({:lua_error, reason}, _r, _s, _log, _d), do: {:error, {:lua_error, reason}}
  defp finish({:crashed, reason}, _r, _s, _log, _d), do: {:error, {:crashed, reason}}

  defp stats(reductions, started, log) do
    %{
      reductions: reductions,
      time_ms: System.monotonic_time(:millisecond) - started,
      log: log
    }
  end

  defp flush(pid) do
    receive do
      {^pid, _, _, _, _} -> :ok
      {:DOWN, _, :process, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  end
end
