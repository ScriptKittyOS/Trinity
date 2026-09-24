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
    # ConnCase does not stop the session processes a test starts, and a child left running holds
    # the sandbox connection past its owner, which fails the *next* test's setup rather than this
    # one's. Cleaned up here for the same reason SessionCase does it.
    on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)

    {:ok, parent} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "parent"})

    {:ok, parent: parent}
  end

  test "a short id distinguishes children rather than sharing a prefix with them" do
    ids = for _ <- 1..4, do: Trinity.UUID.generate()

    # Measured, not assumed: four ids generated together had one distinct 8-character prefix
    # between them, which is what sent the first version of this panel out with four identical
    # labels.
    assert ids |> Enum.map(&String.slice(&1, 0, 8)) |> Enum.uniq() |> length() == 1
    assert ids |> Enum.map(&Subagents.short_id/1) |> Enum.uniq() |> length() == 4
  end

  test "a finished child is shown as done, with no stop control", %{conn: conn, parent: parent} do
    Fake.scripts([script_deltas(1, "finished ")])
    {:ok, result} = Subagents.delegate(parent.id, "a brief that completes")

    {:ok, _live, html} = live(conn, ~p"/s/#{parent.id}")

    # The row's own status is still "active" here, because that field is the session lifecycle.
    assert Sessions.get_session(result.session_id).status == "active"

    # The panel must not repeat that: the child has finished, and offering to stop it is a button
    # that does nothing.
    assert html =~ "done"
    refute html =~ ~s(phx-value-id="#{result.session_id}")
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
    # The tail, not the head: these ids are UUIDv7 and children made in the same second share
    # their leading bytes, so a head-based short id tells two rows apart only by accident.
    assert html =~ Subagents.short_id(result.session_id)
    assert html =~ "done"
    assert html =~ ~s(href="/s/#{result.session_id}")
  end

  test "stopping a running subagent cancels it, and the panel survives", %{
    conn: conn,
    parent: parent
  } do
    # A child left running, so there is a stop control to press. {:sleep, ms} holds the turn open;
    # a script that merely omits its terminator does not, which is a lesson from this slice's
    # supervision test.
    Fake.scripts([[{:text_delta, "working "}, {:sleep, 30_000}, {:done, :stop}]])
    task = Task.async(fn -> Subagents.delegate(parent.id, "a brief to stop") end)

    # The row exists before the process does: create_child/3 inserts the session, and the turn
    # starts after. Waiting for the row and asserting running? in the same breath is a race the
    # first version of this test lost.
    child_id = await_child(parent.id)
    assert await_running(child_id), "the child never reached a running state"

    {:ok, live, _html} = live(conn, ~p"/s/#{parent.id}")

    html =
      live
      |> element(~s(#subagents button[phx-value-id="#{child_id}"]))
      |> render_click()

    # The page still renders and still knows about the child; cancelling is not deleting.
    assert html =~ "a brief to stop"
    Task.await(task, 30_000)
  end

  defp await_running(session_id, attempts \\ 200) do
    cond do
      Subagents.running?(session_id) -> true
      attempts > 0 -> Process.sleep(10) && await_running(session_id, attempts - 1)
      true -> false
    end
  end

  defp await_child(parent_id, attempts \\ 200) do
    case Subagents.children(parent_id) do
      [child | _] -> child.id
      [] when attempts > 0 -> Process.sleep(10) && await_child(parent_id, attempts - 1)
      [] -> flunk("no child session appeared")
    end
  end

  defp script_deltas(n, text) do
    Enum.map(1..n, fn _ -> {:text_delta, text} end) ++
      [{:usage, %{input_tokens: n, output_tokens: n}}, {:done, :stop}]
  end
end
