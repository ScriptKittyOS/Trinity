# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ReceiptsLiveTest do
  @moduledoc "Slice 024: the receipts pages read the chain and verify it; they write nothing."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Effects
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools.Context

  @note_args %{"path" => "/home/me/notes/a.md", "text" => "hi"}

  setup do
    session = Trinity.Factory.session!()
    scope = Receipts.session_scope(session.id)
    {:ok, rule} = Permissions.put_rule(%{tool: "write_note", pattern: "*", decision: "allow"})

    on_exit(fn ->
      Permissions.revoke_rule(rule.id)
      Receipts.stop_writer(scope)
    end)

    {:ok, session: session, scope: scope}
  end

  test "a session's chain: the rows in order, signed or checkpointed, and verify runs to exit 0",
       %{conn: conn, session: session} do
    ctx = %Context{session_id: session.id, caller: session.id}

    [{_, {:ok, _, _}}, {_, {:ok, _, _}}] =
      Effects.Runner.run_all(
        [
          %{id: "c1", name: "echo", args: %{"text" => "hi"}},
          %{id: "c2", name: "write_note", args: @note_args}
        ],
        ctx
      )

    {:ok, view, html} = live(conn, ~p"/s/#{session.id}/receipts")
    assert html =~ "session:" <> session.id
    assert html =~ "5 receipts"
    assert has_element?(view, "#receipt-1")
    assert has_element?(view, "#receipt-5")
    assert html =~ "checkpointed"
    assert html =~ "signed"

    html = view |> element("#verify") |> render_click()
    assert html =~ "verified: 5 receipts, 0 checkpoints, exit 0"
    assert has_element?(view, "#verify-outcome")
  end

  test "an empty scope says so", %{conn: conn, session: session} do
    {:ok, _view, html} = live(conn, ~p"/s/#{session.id}/receipts")
    assert html =~ "Nothing receipted in this scope yet."
  end

  test "the chat links to its receipts", %{conn: conn, session: session} do
    {:ok, view, _html} = live(conn, ~p"/s/#{session.id}")
    assert has_element?(view, "#receipts-link")
  end

  test "the boot page shows this run's boot receipt with the authority, the signer and the policy hash, and verifies",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/receipts/boot")
    boot = Receipts.boot_receipt()
    assert has_element?(view, "#boot-receipt")
    assert html =~ "Trinity.Authority.Local"
    assert html =~ boot.subject["signer"]["key_id"]
    assert html =~ boot.meta["core_policy_hash"]
    assert html =~ boot.receipt_hash
    html = view |> element("#verify") |> render_click()
    assert html =~ "verified: "
    assert html =~ "exit 0"
  end
end
