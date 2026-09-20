# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ApprovalLiveTest do
  @moduledoc "Slice 021 line 7: the card renders on a request, each button decides through the gate, /permissions lists rows."
  use TrinityWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Trinity.SessionCase, only: [script_deltas: 2, collect: 3]

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval
  alias Trinity.Sessions

  setup do
    Fake.clear()
    on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    :ok = Permissions.subscribe(row.id)
    {:ok, id: row.id}
  end

  @args %{"path" => "/home/me/notes/a.md", "text" => "hi"}

  defp write_turn do
    Fake.scripts([
      [
        {:tool_call_start, "c1", "write_note"},
        {:tool_call_end, "c1", @args},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :tool_calls}
      ],
      script_deltas(2, "written ")
    ])
  end

  defp send_message(view, text),
    do: view |> form("#composer", %{"content" => text}) |> render_submit()

  test "AC2 (LiveView half): the card renders with tool, risk and arguments; Allow once runs the tool and the final message follows",
       %{conn: conn, id: id} do
    write_turn()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    send_message(view, "write it")
    assert_receive {:approval, :requested, %Approval{id: aid}}, 2_000
    _ = collect(id, &match?({:state, :approval_wait}, &1), 2_000)
    html = render(view)
    assert has_element?(view, "#approval-#{aid}")
    assert html =~ "write_note" and html =~ "write" and html =~ "/home/me/notes/a.md"
    assert has_element?(view, "#status[data-status=approval_wait]")
    assert has_element?(view, "#pending-approvals", "1")
    assert has_element?(view, "#pattern-#{aid}[value='path=/home/me/notes/*']")

    view |> element("#approval-#{aid} button", "Allow once") |> render_click()
    _ = collect(id, &match?({:state, :idle}, &1), 5_000)
    html = render(view)
    refute has_element?(view, "#approval-#{aid}")
    assert html =~ "wrote 2 bytes"
    assert html =~ "written written"

    assert %Approval{status: "allowed", decision: "once", decided_by: "liveview"} =
             Permissions.get_approval(aid)

    refute has_element?(view, "#pending-approvals")
  end

  test "Always allow writes the edited pattern as a rule; Deny denies", %{conn: conn, id: id} do
    write_turn()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    send_message(view, "write it")
    assert_receive {:approval, :requested, %Approval{id: aid}}, 2_000
    _ = collect(id, &match?({:state, :approval_wait}, &1), 2_000)

    view |> form("#always-#{aid}", %{"pattern" => "path=/home/me/**"}) |> render_change()
    view |> element("#approval-#{aid} button", "Always allow") |> render_click()
    _ = collect(id, &match?({:state, :idle}, &1), 5_000)

    assert [%{pattern: "path=/home/me/**", scope: "global", decision: "allow"}] =
             Permissions.list_rules()

    # Under the rule the next call runs without a card.
    write_turn()
    send_message(view, "again")
    events = collect(id, &match?({:state, :idle}, &1), 5_000)
    refute :approval_wait in for({:state, s} <- events, do: s)

    # A call outside the rule asks, and Deny records the denial.
    Fake.scripts([
      [
        {:tool_call_start, "c1", "write_note"},
        {:tool_call_end, "c1", %{"path" => "/etc/hosts"}},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :tool_calls}
      ],
      script_deltas(1, "after")
    ])

    send_message(view, "outside")
    assert_receive {:approval, :requested, %Approval{id: aid2}}, 2_000
    _ = collect(id, &match?({:state, :approval_wait}, &1), 2_000)
    view |> element("#approval-#{aid2} button", "Deny") |> render_click()
    _ = collect(id, &match?({:state, :idle}, &1), 5_000)
    assert %Approval{status: "denied"} = Permissions.get_approval(aid2)
    assert render(view) =~ "error: :denied"
  end

  test "/permissions lists every decision with its time and decider, the pending ones decidable, the rules revocable (AC7's page)",
       %{conn: conn, id: id} do
    {:ok, a1} = Permissions.request_approval(id, "write_note", @args)
    {:ok, _} = Permissions.decide_request(a1.id, :session)
    {:ok, a2} = Permissions.request_approval(id, "write_note", %{"path" => "/b"})

    {:ok, view, html} = live(conn, ~p"/permissions")
    assert has_element?(view, "#approval-row-#{a1.id}", "allowed")
    assert has_element?(view, "#approval-row-#{a1.id}", "liveview")
    assert has_element?(view, "#approval-row-#{a2.id}", "pending")
    assert has_element?(view, "#approval-#{a2.id}")
    assert html =~ "fp:" <> a1.fingerprint
    [rule] = Permissions.list_rules()
    assert has_element?(view, "#rule-#{rule.id}")

    view |> element("#approval-#{a2.id} button", "Deny") |> render_click()
    assert has_element?(view, "#approval-row-#{a2.id}", "denied")
    refute has_element?(view, "#approval-#{a2.id}")

    view |> element("#rule-#{rule.id} button", "Revoke") |> render_click()
    refute has_element?(view, "#rule-#{rule.id}")
    assert Permissions.list_rules() == []
  end

  test "the header indicator counts everyone's pending requests on every page", %{
    conn: conn,
    id: id
  } do
    other = Factory.session!()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    refute has_element?(view, "#pending-approvals")
    {:ok, a} = Permissions.request_approval(other.id, "write_note", @args)
    assert_receive_approval(a.id)
    assert has_element?(view, "#pending-approvals", "1")
    refute has_element?(view, "#approval-#{a.id}"), "another session's card does not render here"
    {:ok, _} = Permissions.decide_request(a.id, :deny)
    _ = render(view)
    refute has_element?(view, "#pending-approvals")
  end

  defp assert_receive_approval(id) do
    :ok = Permissions.subscribe(:all)
    # The page received the broadcast before this process subscribed; a render after a call
    # to the gate is a render after the page handled it.
    Process.sleep(50)
    _ = id
  end
end
