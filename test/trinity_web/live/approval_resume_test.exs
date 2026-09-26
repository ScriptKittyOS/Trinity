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
  import Trinity.SessionCase, only: [script_deltas: 2]

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

  # A deadline, not a synchronisation with the session's internals. `collect/3` cannot be used to
  # wait for the end of the turn here: it reads the mailbox, and an `{:state, :idle}` broadcast from
  # before the message was sent is already sitting in it, so it returns at once and the assertion
  # runs while the turn is still in flight. That mistake made an early version of this file fail for
  # a reason that had nothing to do with the defect.
  defp wait_until(fun, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait(fun, deadline)
    end
  end

  # The turn has settled when it has produced an outcome for the call, whichever outcome that is.
  defp settled?(view), do: render(view) =~ "wrote 2 bytes" or render(view) =~ "timed out"

  test "AC1: an allow clicked on the requested broadcast, with no wait for approval_wait, consumes the row and runs the call",
       %{conn: conn, id: id} do
    write_turn()
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    send_message(view, "write it")

    # The only synchronisation a browser has: the card is on the page. Waiting for it is not the
    # same as waiting for `approval_wait`. The test process and the LiveView subscribe to the same
    # topic, so the test can win that race and look before the view has re-rendered; a browser
    # cannot click a card that is not painted yet either way.
    assert_receive {:approval, :requested, %Approval{id: aid}}, 5_000

    assert wait_until(fn -> has_element?(view, "#approval-#{aid}") end),
           "the approval card never rendered"

    view |> element("#approval-#{aid} button", "Allow once") |> render_click()

    _ = wait_until(fn -> settled?(view) end)

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
    assert wait_until(fn -> has_element?(view, "#approval-#{aid}") end)
    view |> element("#approval-#{aid} button", "Allow once") |> render_click()
    _ = wait_until(fn -> settled?(view) end)

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

    _ = wait_until(fn -> Permissions.get_approval(aid).consumed_at != nil end)

    assert Permissions.get_approval(aid).consumed_at,
           "a decision made through the gate at the first observable instant was not applied"
  end

  test "AC6: an approval event with no held call to apply it to is logged and receipted, never dropped in silence",
       %{id: id} do
    # No turn at all: the session is idle, so a decision broadcast to it has nothing to apply. That
    # is the shape that used to return :keep_state_and_data and say nothing.
    {:ok, _pid} = Trinity.Sessions.ensure_started(id)

    {:ok, approval} =
      Permissions.request_approval(id, "write_note", @args, risk: :write, cwd: nil)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = Permissions.decide_request(approval.id, :once, decided_by: "test")

        wait_until(fn ->
          ("session:" <> id)
          |> Receipts.list()
          |> Enum.any?(&(&1.subject_ref == "approval_dropped:#{id}:#{approval.id}"))
        end)
      end)

    assert log =~ "with no held call to apply it to",
           "the drop was not logged. A decision the owner made went nowhere and said nothing."

    row =
      ("session:" <> id)
      |> Receipts.list()
      |> Enum.find(&(&1.subject_ref == "approval_dropped:#{id}:#{approval.id}"))

    assert row, "the drop was not receipted"
    assert {:ok, body} = JSON.decode(row.signed_payload)
    assert get_in(body, ["decision", "outcome"]) == "dropped"
    assert get_in(body, ["decision", "reason"]) =~ "no held call"
  end
end
