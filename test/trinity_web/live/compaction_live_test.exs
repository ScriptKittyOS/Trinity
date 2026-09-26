# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.CompactionLiveTest do
  @moduledoc "Slice 023 line 5: the context indicator, the compaction card, and the redirect on a fork."
  use TrinityWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Trinity.SessionCase, only: [script_deltas: 2, collect: 3, await_event: 3]

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions

  setup do
    Fake.clear()
    on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    {:ok, id: row.id}
  end

  test "the indicator shows the estimate against the window and climbs with the history", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    # The window comes from the registry rather than being typed here, so resizing the test
    # model does not silently break an assertion about something else.
    window = Trinity.Memory.Tokens.context_tokens("fake:chat")
    assert has_element?(view, "#context[data-window='#{window}']")
    [used] = Regex.run(~r/data-used="(\d+)"/, render(view), capture: :all_but_first)
    before = String.to_integer(used)
    Fake.script(script_deltas(20, "word "))

    view
    |> form("#composer", %{"content" => "a message with enough words to move the estimate"})
    |> render_submit()

    # The final message, not the first idle: the init's idle is already in this mailbox (NOTES 9).
    _ = collect(id, &match?({:assistant_message, _}, &1), 5_000)
    [after_used] = Regex.run(~r/data-used="(\d+)"/, render(view), capture: :all_but_first)
    assert String.to_integer(after_used) > before
    assert render(view) =~ "context #{after_used} / #{window}"
  end

  test "a compaction row renders as a card naming its range; the originals stay on the page", %{
    conn: conn,
    id: id
  } do
    Factory.message!(id, %{role: "user", content: "one"})
    Factory.message!(id, %{role: "assistant", content: "two"})

    {:ok, c} =
      Sessions.append_message(id, %{
        role: "system",
        content: "Compacted summary of messages 1 to 2.\n\n### Summary\nthey said one and two",
        parts: %{
          "compaction" => %{
            "from_seq" => 1,
            "to_seq" => 2,
            "rows" => 2,
            "digests" => [],
            "summary" => "they said one and two"
          },
          "taint" => "trusted"
        }
      })

    {:ok, view, html} = live(conn, ~p"/s/#{id}")
    assert has_element?(view, "#message-#{c.id} details")
    assert html =~ "messages 1 to 2, 2 rows"
    assert html =~ "they said one and two"
    assert html =~ "View the original messages (from 1)"
    assert html =~ "one" and html =~ "two"
    refute html =~ "untrusted sources"
  end

  test "a fork moves the page to the child session", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/s/#{id}")
    child = Factory.session!(%{parent_id: id})
    Trinity.Sessions.Events.broadcast(id, {:forked, child.id})
    assert_redirect(view, "/s/#{child.id}")
  end
end
