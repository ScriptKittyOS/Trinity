# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.SessionFlowTest do
  @moduledoc """
  Slice 021 through a Session: AC1 (a read tool never reaches the Gate), AC2's test half
  (approval_wait, allow once, the tool runs, the final message), AC3, AC5 and AC8.
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval

  setup do
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    :ok = Permissions.subscribe(row.id)
    {:ok, id: row.id}
  end

  @args %{"path" => "/home/me/notes/a.md", "text" => "hi"}

  defp tool_turn(calls, final \\ "done ") do
    starts = for {id, name, _} <- calls, do: {:tool_call_start, id, name}
    ends = for {id, _, args} <- calls, do: {:tool_call_end, id, args}

    Fake.scripts([
      starts ++ ends ++ [{:usage, %{input_tokens: 1, output_tokens: 1}}, {:done, :tool_calls}],
      script_deltas(2, final)
    ])
  end

  defp tool_rows(id), do: id |> Sessions.history() |> Enum.filter(&(&1.role == "tool"))

  test "AC1: a read-risk tool runs with no request: the Gate sees nothing", %{id: id} do
    :ok = Permissions.subscribe(:all)
    tool_turn([{"c1", "echo", %{"text" => "plain"}}])
    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "go")
    events = collect(id, &match?({:state, :idle}, &1))
    refute :approval_wait in for({:state, s} <- events, do: s)
    refute_received {:approval, _, _}
    assert Permissions.list_approvals(session_id: id) == []
    assert [%{content: "plain"}] = tool_rows(id)
  end

  test "AC2 (test half): a write-risk call enters approval_wait; allow once runs it; the final message follows",
       %{id: id} do
    tool_turn([{"c1", "write_note", @args}])
    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "write")

    assert_receive {:approval, :requested,
                    %Approval{id: aid, tool: "write_note", status: "pending"}},
                   2_000

    _ = collect(id, &match?({:state, :approval_wait}, &1))
    assert %{state: :approval_wait} = Session.state(pid)
    assert [%Approval{id: ^aid}] = Permissions.pending(id)

    {:ok, _} = Permissions.decide_request(aid, :once)
    events = collect(id, &match?({:state, :idle}, &1))

    assert {:assistant_message, %{content: "done done "}} =
             Enum.find(events, &match?({:assistant_message, _}, &1))

    assert [row] = tool_rows(id)
    assert row.parts["ok"] == true and row.content =~ "wrote 2 bytes"
    assert %Approval{status: "allowed", consumed_at: %DateTime{}} = Permissions.get_approval(aid)
  end

  test "AC3: allow for session: the second identical call runs without asking; other arguments ask; a new session asks",
       %{id: id} do
    tool_turn([{"c1", "write_note", @args}])
    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "one")
    assert_receive {:approval, :requested, %Approval{id: aid}}, 2_000
    {:ok, _} = Permissions.decide_request(aid, :session)
    _ = collect(id, &match?({:state, :idle}, &1))

    # The same call again: no request.
    tool_turn([{"c1", "write_note", @args}])
    {:ok, _} = Session.send_user_message(pid, "two")
    events = collect(id, &match?({:state, :idle}, &1))
    refute :approval_wait in for({:state, s} <- events, do: s)
    refute_received {:approval, :requested, _}
    assert length(tool_rows(id)) == 2

    # Other arguments under the same grant: a request again (M2: the fingerprint differs).
    tool_turn([{"c1", "write_note", Map.put(@args, "text", "changed")}])
    {:ok, _} = Session.send_user_message(pid, "three")
    assert_receive {:approval, :requested, %Approval{id: aid3}}, 2_000
    {:ok, _} = Permissions.decide_request(aid3, :deny)
    _ = collect(id, &match?({:state, :idle}, &1))

    # A new session: asks.
    other = Factory.session!()
    :ok = Permissions.subscribe(other.id)
    tool_turn([{"c1", "write_note", @args}])
    {:ok, opid} = start_drained(other.id)
    {:ok, _} = Session.send_user_message(opid, "one")
    assert_receive {:approval, :requested, %Approval{session_id: sid}}, 2_000
    assert sid == other.id
  end

  test "AC5: deny: the tool row carries a denial the model reads; the turn goes on to a final message",
       %{id: id} do
    tool_turn([{"c1", "write_note", @args}, {"c2", "echo", %{"text" => "fine"}}], "after denial ")
    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "write")
    assert_receive {:approval, :requested, %Approval{id: aid}}, 2_000
    {:ok, _} = Permissions.decide_request(aid, :deny)
    events = collect(id, &match?({:state, :idle}, &1))

    assert Enum.any?(
             events,
             &match?({:assistant_message, %{content: "after denial after denial "}}, &1)
           )

    rows = tool_rows(id)
    assert Enum.map(rows, & &1.tool_call_id) == ["c2", "c1"]
    denied = Enum.find(rows, &(&1.tool_call_id == "c1"))
    assert denied.parts["ok"] == false and denied.content == "error: :denied"

    assert Enum.map(Sessions.history(id), & &1.role) == [
             "user",
             "assistant",
             "tool",
             "tool",
             "assistant"
           ]
  end

  test "AC8: killed in approval_wait, the request is still pending and decidable; the restarted session is idle",
       %{id: id} do
    tool_turn([{"c1", "write_note", @args}])
    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "write")
    assert_receive {:approval, :requested, %Approval{id: aid}}, 2_000
    _ = collect(id, &match?({:state, :approval_wait}, &1))

    Process.exit(pid, :kill)
    _ = collect(id, &match?({:state, :idle}, &1))
    {:ok, new_pid} = Sessions.ensure_started(id)
    assert new_pid != pid
    assert %{state: :idle, pending: []} = Session.state(new_pid)

    assert [%Approval{id: ^aid, status: "pending"}] = Permissions.pending(id)

    assert {:ok, %Approval{status: "allowed", decided_at: %DateTime{}}} =
             Permissions.decide_request(aid, :once)

    assert_receive {:approval, :decided, %Approval{id: ^aid}}
    assert Permissions.pending(id) == []
    # The turn that asked is gone with the process (012 AC9); the grant was recorded, not run.
    assert tool_rows(id) == []
    {:ok, _} = Session.send_user_message(new_pid, "again")
    _ = collect(id, &match?({:state, :idle}, &1))
  end
end
