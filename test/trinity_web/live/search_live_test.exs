# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SearchLiveTest do
  @moduledoc "Slice 031 AC5's automatic half: the page renders hits with marks and deep-links into the session at the message."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.{Factory, Sessions}

  setup do
    session = Factory.session!(%{title: "Release planning"})

    {:ok, m} =
      Sessions.append_message(session.id, %{role: "user", content: "we decided to ship on friday"})

    {:ok, session: session, message: m}
  end

  test "a query in the URL renders its hits, marked, linking to the session at the message", %{
    conn: conn,
    session: session,
    message: m
  } do
    {:ok, view, html} = live(conn, ~p"/search?q=decided")
    assert html =~ "1 hits for decided"
    assert has_element?(view, "#hit-#{m.id}")
    assert html =~ "<mark>decided</mark>"
    assert html =~ "Release planning"
    assert html =~ ~s(href="/s/#{session.id}#message-#{m.id}")
  end

  test "submitting the form patches the URL and searches; nothing matching says so", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/search")
    html = view |> form("#search-form", q: "zebra") |> render_submit()
    assert_patch(view, "/search?q=zebra")
    assert html =~ "Nothing matches zebra."
    refute has_element?(view, "#hits")
  end

  test "the index and the chat link to the search page", %{conn: conn, session: session} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#search-link")
    {:ok, view, _} = live(conn, ~p"/s/#{session.id}")
    assert has_element?(view, "#search-link")
  end
end
