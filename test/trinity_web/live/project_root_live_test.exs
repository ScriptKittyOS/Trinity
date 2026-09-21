# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ProjectRootLiveTest do
  @moduledoc "Slice 033: the project root field in the chat's bar saves the setting; a bad path is refused."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.{Factory, Sessions}

  @fixtures Path.expand("../../support/fixtures/agents", __DIR__)

  test "the field saves an existing directory, refuses a missing one, and clears on empty", %{
    conn: conn
  } do
    session = Factory.session!()
    {:ok, view, _} = live(conn, ~p"/s/#{session.id}")
    root = Path.join(@fixtures, "plain")
    view |> form("#project-root", project_root: root) |> render_submit()
    assert Sessions.get_session(session.id).project_root == root
    assert has_element?(view, "#project-root input[value='#{root}']")

    html = view |> form("#project-root", project_root: "/no/such/dir") |> render_submit()
    assert html =~ "Project root not set"
    assert Sessions.get_session(session.id).project_root == root

    view |> form("#project-root", project_root: "") |> render_submit()
    assert Sessions.get_session(session.id).project_root == nil
  end
end
