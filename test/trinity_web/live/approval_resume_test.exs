# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ApprovalResumeTest do
  @moduledoc """
  Slice 126: an allow the owner issued always consumes its approval and runs the call.

  The invariant, set by the owner before work started: an allow either consumes the row, runs the
  tool and leaves the allow receipt on the same chain as the ask, or it fails closed with a receipt
  naming why it could not be consumed. `consumed_at: nil` after a granted allow is a defect and
  never a timeout.

  Every approval test before this one calls `collect(id, &match?({:state, :approval_wait}, &1))`
  before clicking. That is a synchronisation the product does not have: the card is rendered from the
  gate's `:requested` broadcast, which is emitted from inside the tool task, before the Session has
  returned from `start_tools`. So the suite only ever exercised the ordering that works. These tests
  deliberately do not wait.
  """
  use TrinityWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Trinity.SessionCase, only: [script_deltas: 2, collect: 3]

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval
  alias Trinity.Receipts

  setup do
    Fake.clear()
    on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)
    row = Factory.session!()
    :ok = Trinity.Sessions.subscribe(row.id)
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

  test "AC1: an allow clicked on the requested broadcast, with no wait for approval_wait, consumes the row and runs the call",
       %{conn: conn, id: id} do
    write_turn()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    send_message(view, "write it")

    # The only synchronisation a browser has: the card is on the page.
    assert_receive {:approval, :requested, %Approval{id: aid}}, 5_000
    assert has_element?(view, "#approval-#{aid}")

    view |> element("#approval-#{aid} button", "Allow once") |> render_click()

    _ = collect(id, &match?({:state, :idle}, &1), 15_000)

    approval = Permissions.get_approval(aid)
    assert approval.status == "allowed"
    assert approval.decision == "once"

    assert approval.consumed_at,
           "the owner allowed this call and the grant was never consumed. consumed_at is nil, " <>
             "which is the signature of the decision being dropped rather than applied: the click " <>
             "landed before the session had left tool_wait"

    html = render(view)

    assert html =~ "wrote 2 bytes",
           "the approved call did not run. Rendered instead: " <>
             (html |> String.replace(~r/<[^>]*>/, " ") |> String.replace(~r/\s+/, " "))

    refute html =~ "timed out",
            "an allow the owner issued was reported as a timeout"
  end

  test "AC3/AC4: the chain reads ask then allow, both on the same scope, and neither is a timeout",
       %{conn: conn, id: id} do
    write_turn()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    send_message(view, "write it")

    assert_receive {:approval, :requested, %Approval{id: aid}}, 5_000
    view |> element("#approval-#{aid} button", "Allow once") |> render_click()
    _ = collect(id, &match?({:state, :idle}, &1), 15_000)

    rows = Receipts.list("session:" <> id)
    decisions = Enum.filter(rows, &(&1.kind == "decision"))

    outcomes =
      for r <- decisions, {:ok, body} <- [JSON.decode(r.signed_payload)] do
        get_in(body, ["decision", "outcome"])
      end

    assert "ask" in outcomes, "no ask receipt on the session chain: #{inspect(outcomes)}"

    assert "allow" in outcomes,
           "the ask was receipted and the allow was not, on chain #{inspect(outcomes)}. The owner " <>
             "answered and the chain does not carry the answer"

    assert Enum.find_index(outcomes, &(&1 == "ask")) <
             Enum.find_index(outcomes, &(&1 == "allow")),
           "the allow is not after the ask on the chain: #{inspect(outcomes)}"
  end

  test "AC5: at the instant the requested broadcast is observable, the session can already accept a decision",
       %{conn: conn, id: id} do
    write_turn()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    send_message(view, "write it")

    assert_receive {:approval, :requested, %Approval{id: aid}}, 5_000

    # Decide straight through the gate, with no LiveView in the way at all, at the first instant
    # the request is observable by anyone. Nothing in the product may require the caller to know
    # what state the Session is in.
    assert {:ok, _} = Permissions.decide_request(aid, :once, decided_by: "test")

    _ = collect(id, &match?({:state, :idle}, &1), 15_000)

    assert Permissions.get_approval(aid).consumed_at,
           "a decision made through the gate at the first observable instant was not applied"
  end
end
