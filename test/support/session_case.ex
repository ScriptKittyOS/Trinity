# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SessionCase do
  @moduledoc """
  A DataCase for tests that run session processes. Slice 012. The sandbox is shared so the
  session process and its Tasks use the test's connection; every session started during the
  test is stopped on exit so the connection is not used after the owner is gone.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Trinity.DataCase, async: false
      import Trinity.SessionCase
      alias Trinity.Sessions
      alias Trinity.Sessions.{Events, Session}

      setup do
        Trinity.LLM.Providers.Fake.clear()
        on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)
        :ok
      end
    end
  end

  @doc "Stops every session process under the supervisor, waiting for each."
  def stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Trinity.Sessions.Supervisor),
        is_pid(pid) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Trinity.Sessions.Supervisor, pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  @doc """
  Starts the session (or finds it) and drains the `{:state, :idle}` its init broadcasts, so a
  collection that waits for idle waits for the turn's idle and not the first one.
  """
  def start_drained(session_id) do
    {:ok, pid} = Trinity.Sessions.ensure_started(session_id)

    receive do
      {:session, ^session_id, {:state, :idle}} -> :ok
    after
      1_000 -> :ok
    end

    {:ok, pid}
  end

  @doc "Collects session events for `session_id` until `until` matches or the timeout passes."
  def collect(session_id, until, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(session_id, until, deadline, [])
  end

  defp do_collect(session_id, until, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:session, ^session_id, event} ->
        acc = [event | acc]

        if until.(event),
          do: Enum.reverse(acc),
          else: do_collect(session_id, until, deadline, acc)
    after
      remaining -> Enum.reverse(acc)
    end
  end

  @doc "The fake's script that emits `n` deltas of `text` then usage and done."
  def script_deltas(n, text \\ "x") do
    Enum.map(1..n, fn _ -> {:text_delta, text} end) ++
      [{:usage, %{input_tokens: n, output_tokens: n}}, {:done, :stop}]
  end
end
