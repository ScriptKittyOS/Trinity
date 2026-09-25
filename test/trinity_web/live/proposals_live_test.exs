# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ProposalsLiveTest do
  @moduledoc """
  Slice 042 AC1 and AC4, as the owner sees them.

  The assertion that matters is not that a proposal renders. It is **where** it renders: in its own
  section, read in a calm moment, and never beside a pending request. A recommendation offered at the
  moment of deciding changes the decision, and this project's permission model rests on that decision
  being the owner's own.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Permissions
  alias Trinity.Permissions.Approval
  alias Trinity.Repo

  defp decided!(tool, status, n) do
    session = Trinity.Factory.session!()

    for i <- 1..n do
      Repo.insert!(%Approval{
        session_id: session.id,
        tool: tool,
        args: %{"n" => i},
        risk: "write",
        fingerprint: "fp-#{tool}-#{i}-#{System.unique_integer([:positive])}",
        status: status,
        decision: if(status == "allowed", do: "once", else: "deny"),
        decided_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
    end
  end

  test "with nothing decided neither section appears", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/permissions")
    refute html =~ "Rules your decisions imply"
    refute html =~ "Decisions that did not agree"
  end

  test "a unanimous history proposes a rule, with the count it rests on", %{conn: conn} do
    decided!("fs_read", "allowed", 7)

    {:ok, _live, html} = live(conn, ~p"/permissions")

    assert html =~ "Rules your decisions imply"
    assert html =~ "fs_read"
    assert html =~ "7"

    assert html =~ "would change the decision" or html =~ "pending request",
           "the section does not say why it is not beside the request, which is the whole reason " <>
             "it is a separate section"
  end

  test "accepting writes an ordinary rule and the proposal goes away", %{conn: conn} do
    decided!("fs_read", "allowed", 7)
    assert Permissions.list_rules() == []

    {:ok, live, _html} = live(conn, ~p"/permissions")

    html =
      live
      |> element(~s{#proposal-fs_read button[phx-click="proposal_accept"]})
      |> render_click()

    assert [rule] = Permissions.list_rules()
    assert rule.tool == "fs_read"
    assert rule.decision == "allow"
    assert rule.pattern == "*"

    refute html =~ "Rules your decisions imply",
           "the proposal survived being accepted, so the owner would be asked to write it twice"

    # AC6. A rule outlives the session that prompted it, so it is receipted in its own scope with
    # the evidence it rested on. Without the count a reader cannot tell a rule the owner typed from
    # one they accepted, and those are different acts.
    scope = Trinity.Receipts.policy_scope()
    on_exit(fn -> Trinity.Receipts.stop_writer(scope) end)

    assert [receipt] = Trinity.Receipts.list(scope)
    assert receipt.kind == "decision"
    assert receipt.subject["tool"] == "fs_read"
    assert receipt.meta["decisions"] == 7
  end

  test "a disagreement is reported rather than proposed", %{conn: conn} do
    decided!("fs_write", "allowed", 9)
    decided!("fs_write", "denied", 1)

    {:ok, _live, html} = live(conn, ~p"/permissions")

    assert html =~ "Decisions that did not agree"
    assert html =~ "fs_write"

    refute html =~ "Rules your decisions imply",
           "a rule was proposed from a history containing a refusal, which would permit the case " <>
             "the owner refused"
  end
end
