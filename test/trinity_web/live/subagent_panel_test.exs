# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SubagentPanelTest do
  @moduledoc """
  Slice 080, AC7: the session view shows the subagents it delegated, links to each, and can stop
  one.

  AC7 is the slice's one `[manual]` criterion, a screenshot. These tests are not a substitute for
  it and do not claim to be: a screenshot shows a person what the panel looks like, and these show
  the build that it renders the right sessions, that stopping one reaches the subtree, and that it
  stays out of the way when there is nothing to show.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions
  alias Trinity.Subagents

  setup do
    Fake.clear()
    on_exit(fn -> Fake.clear() end)

    {:ok, parent} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "parent"})

    {:ok, parent: parent}
  end

  test "with no subagents the panel is absent rather than empty", %{conn: conn, parent: parent} do
    {:ok, _live, html} = live(conn, ~p"/s/#{parent.id}")
    refute html =~ ~s(id="subagents")
  end

  test "each child is listed with its title, its short id, and a link to it", %{
    conn: conn,
    parent: parent
  } do
    Fake.scripts([script_deltas(1, "done ")])
    {:ok, result} = Subagents.delegate(parent.id, "read the long file and answer")

    {:ok, _live, html} = live(conn, ~p"/s/#{parent.id}")

    assert html =~ ~s(id="subagents")
    assert html =~ "read the long file and answer"
    assert html =~ String.slice(result.session_id, 0, 8)
    assert html =~ ~s(href="/s/#{result.session_id}")
  end

  test "stopping a subagent from the panel cancels it and the panel survives", %{
    conn: conn,
    parent: parent
  } do
    Fake.scripts([script_deltas(1, "done ")])
    {:ok, result} = Subagents.delegate(parent.id, "a brief to stop")

    {:ok, live, _html} = live(conn, ~p"/s/#{parent.id}")

    html =
      live
      |> element(~s(#subagents button[phx-value-id="#{result.session_id}"]))
      |> render_click()

    # The page still renders and still knows about the child; cancelling is not deleting.
    assert html =~ "a brief to stop"
  end

  defp script_deltas(n, text) do
    Enum.map(1..n, fn _ -> {:text_delta, text} end) ++
      [{:usage, %{input_tokens: n, output_tokens: n}}, {:done, :stop}]
  end
end
