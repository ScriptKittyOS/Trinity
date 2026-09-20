# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.CrashTest do
  @moduledoc """
  Slice 012 AC2 (crash test A) and AC9 (kill and reseed twice). The kill is `Process.exit(pid,
  :kill)`, the supervisor restarts the session, and the record is what survives: history rows,
  a draft marked interrupted, and nothing from the dead process.
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.CorePolicy
  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions.Message

  defp wait_for_restart(id, old_pid, tries \\ 50) do
    case Sessions.whereis(id) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ when tries > 0 -> Process.sleep(20) && wait_for_restart(id, old_pid, tries - 1)
      _ -> nil
    end
  end

  test "crash test A: a kill mid-stream restarts the session, keeps history, marks the draft interrupted, spares a neighbour (AC2)" do
    a = Factory.session!()
    b = Factory.session!()
    :ok = Sessions.subscribe(a.id)
    :ok = Sessions.subscribe(b.id)

    # A slow script: one delta, a pause long enough for the 500 ms draft write, more text, then a long pause.
    Fake.script([
      {:text_delta, "draft text "},
      {:sleep, 700},
      {:text_delta, "more "},
      {:sleep, 5_000},
      {:done, :stop}
    ])

    {:ok, pid_a} = start_drained(a.id)
    {:ok, pid_b} = start_drained(b.id)
    {:ok, _} = Session.send_user_message(pid_a, "hello a")
    {:ok, _} = Session.send_user_message(pid_b, "hello b")
    _ = collect(a.id, &match?({:assistant_delta, "more "}, &1), 3_000)
    assert %{state: :thinking, draft_id: draft_id} = Session.state(pid_a)
    assert is_binary(draft_id), "a draft row should exist by now"

    Process.exit(pid_a, :kill)
    new_pid = wait_for_restart(a.id, pid_a)
    assert is_pid(new_pid) and new_pid != pid_a
    assert {:ok, ^new_pid} = Sessions.ensure_started(a.id)

    assert {:turn_interrupted,
            %Message{id: ^draft_id, parts: %{"interrupted" => true, "draft" => false}}} =
             Enum.find(
               collect(a.id, &match?({:turn_interrupted, _}, &1), 2_000),
               &match?({:turn_interrupted, _}, &1)
             )

    history = Sessions.history(a.id)
    assert Enum.map(history, & &1.role) == ["user", "assistant"]
    assert Enum.at(history, 1).content =~ "draft text"
    assert %{state: :idle, pending: []} = Session.state(new_pid)

    # The neighbour never noticed.
    assert Process.alive?(pid_b)
    assert Sessions.whereis(b.id) == pid_b
    assert %{state: :thinking} = Session.state(pid_b)
  end

  test "kill and reseed twice: one live worker, the core policy hash unchanged, no grant, approval or pending call survives (AC9)" do
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    hash_before = CorePolicy.hash()

    Fake.script([
      {:text_delta, "a"},
      {:tool_call_start, "c1", "t"},
      {:tool_call_end, "c1", %{"x" => 1}},
      {:sleep, 5_000},
      {:done, :tool_calls}
    ])

    {:ok, pid1} = start_drained(row.id)
    {:ok, _} = Session.send_user_message(pid1, "go")
    _ = collect(row.id, &match?({:tool_call, _}, &1), 3_000)
    assert %{pending: [%{id: "c1"}]} = Session.state(pid1)

    Process.exit(pid1, :kill)
    pid2 = wait_for_restart(row.id, pid1)
    assert %{state: :idle, pending: [], turns: 0, draft_id: nil} = Session.state(pid2)

    Process.exit(pid2, :kill)
    pid3 = wait_for_restart(row.id, pid2)
    assert %{state: :idle, pending: [], turns: 0, draft_id: nil} = Session.state(pid3)

    assert [{^pid3, _}] = Registry.lookup(Trinity.Registry, row.id)

    live =
      for {_, p, _, _} <- DynamicSupervisor.which_children(Trinity.Sessions.Supervisor),
          is_pid(p),
          Sessions.whereis(row.id) == p,
          do: p

    assert live == [pid3]
    assert CorePolicy.hash() == hash_before
    assert String.length(hash_before) == 64
  end
end
