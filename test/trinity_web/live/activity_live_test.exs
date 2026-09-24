# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ActivityLiveTest do
  @moduledoc """
  Slice 090, AC6: the Activity page.

  The assertion that matters most here is a negative one. The page shows events, and events carry
  no content by rule (`docs/telemetry.md`); a test that only checked rows appeared would pass
  equally well on a page that had quietly started showing prompts.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Sessions
  alias Trinity.Telemetry
  alias Trinity.Telemetry.Activity

  setup do
    Activity.clear()
    on_exit(&Activity.clear/0)
    :ok
  end

  defp settle, do: Activity.recent()

  test "an empty buffer says so rather than showing an empty box", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/activity")
    assert html =~ "Nothing yet"
  end

  test "events appear, newest first, with their name and their subject", %{conn: conn} do
    Telemetry.approval_requested("write_note", :write, "sess-abc")
    Telemetry.gateway_inbound("console", :placed)
    settle()

    {:ok, _live, html} = live(conn, ~p"/activity")

    assert html =~ "approval.requested"
    assert html =~ "write_note"
    assert html =~ "gateway.inbound"
    assert html =~ "console"
  end

  test "the page shows no conversation content, because the events carry none", %{conn: conn} do
    {:ok, session} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

    ctx = %Trinity.Tools.Context{session_id: session.id}
    {:ok, entry} = Trinity.Tools.Registry.lookup("echo")
    secret = "a-phrase-that-must-never-reach-a-page"

    Trinity.Tools.Runner.call_tool(entry, %{"text" => secret}, ctx)
    settle()

    {:ok, _live, html} = live(conn, ~p"/activity")

    assert html =~ "tool.call.stop"
    assert html =~ "echo"
    refute html =~ secret
  end

  test "filtering by kind and by session narrows the list", %{conn: conn} do
    Telemetry.approval_requested("write_note", :write, "sess-1")
    Telemetry.gateway_inbound("console", :placed)
    settle()

    {:ok, live, _html} = live(conn, ~p"/activity")

    html = live |> form("form[phx-change=filter]", %{"kind" => "approval"}) |> render_change()
    assert html =~ "approval.requested"
    refute html =~ "gateway.inbound"

    html =
      live |> form("form[phx-change=session]", %{"session_id" => "sess-1"}) |> render_change()

    assert html =~ "approval.requested"
  end

  test "clearing empties the buffer", %{conn: conn} do
    Telemetry.approval_requested("write_note", :write, "sess-1")
    settle()

    {:ok, live, _html} = live(conn, ~p"/activity")
    html = live |> element("button[phx-click=clear]") |> render_click()

    assert html =~ "Nothing yet"
  end

  test "the buffer is bounded, so a long run does not grow without limit" do
    for n <- 1..(Activity.limit() + 50) do
      Telemetry.approval_requested("tool-#{n}", :read, "sess-1")
    end

    settle()
    assert length(Activity.recent()) == Activity.limit()
  end
end
