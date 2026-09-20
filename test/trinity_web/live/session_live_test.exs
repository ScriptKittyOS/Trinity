# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SessionLiveTest do
  @moduledoc """
  Slice 013 AC2, AC4 (the test half), AC5, AC6 and AC7, with AC3's test half, through the scripted
  provider. The test subscribes to the same session events as the page; a `render/1` after an
  event is received is a render after the page handled it, because the Session sends both
  mailboxes in order and `render/1` is a call the page answers in order.
  """
  use TrinityWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Trinity.SessionCase, only: [script_deltas: 2, collect: 3]

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

  defp send_message(view, text) do
    view |> form("#composer", %{"content" => text}) |> render_submit()
  end

  defp wait_for(id, until, timeout \\ 5_000), do: collect(id, until, timeout)

  describe "the index" do
    test "lists sessions, and New session creates a row and opens it", %{conn: conn, id: id} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "message-" == false
      assert has_element?(view, "#sessions-#{id}")
      before = length(Sessions.list_sessions())

      assert {:error, {:live_redirect, %{to: "/s/" <> new_id}}} =
               view |> element("#new-session") |> render_click()

      assert length(Sessions.list_sessions()) == before + 1
      assert Sessions.get_session(new_id).persona_id == Sessions.default_persona().id
    end

    test "Ctrl/Cmd+K reaches the same event through the Shortcuts hook", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      assert {:error, {:live_redirect, %{to: "/s/" <> _}}} = render_hook(view, "new_session", %{})
    end

    test "a missing session redirects home with a flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/s/#{Trinity.UUID.generate()}")
    end
  end

  describe "a turn (AC2)" do
    test "send, deltas update the draft, the final message appears once", %{conn: conn, id: id} do
      # A pause after the first delta, so the page is caught mid-stream.
      Fake.script([{:text_delta, "word "}, {:sleep, 500}] ++ script_deltas(29, "word "))
      {:ok, view, _} = live(conn, ~p"/s/#{id}")
      assert has_element?(view, "#status[data-status=idle]")

      send_message(view, "hello **there**")
      _ = wait_for(id, &match?({:assistant_delta, _}, &1))
      html = render(view)
      assert html =~ "hello **there**"
      assert has_element?(view, "#draft")
      assert has_element?(view, "#status[data-status=thinking]")
      assert has_element?(view, "#cancel")

      _ = wait_for(id, &match?({:state, :idle}, &1))
      html = render(view)
      final = String.duplicate("word ", 30) |> String.trim()
      assert length(String.split(html, final)) - 1 == 1, "the final text appears more than once"
      refute has_element?(view, "#draft")
      assert has_element?(view, "#status[data-status=idle]")
      [user, assistant] = Sessions.history(id)
      assert has_element?(view, "#message-#{user.id}")
      assert has_element?(view, "#message-#{assistant.id}")
      assert html =~ "29/29"
      assert Sessions.get_session(id).title == "hello **there**"
    end
  end

  describe "cancel (AC3, the test half)" do
    test "the partial text is kept as interrupted, the banner shows, Retry sends again", %{
      conn: conn,
      id: id
    } do
      Fake.scripts([
        [{:text_delta, "partial "}, {:sleep, 3_000}, {:text_delta, "never"}, {:done, :stop}],
        script_deltas(2, "again ")
      ])

      {:ok, view, _} = live(conn, ~p"/s/#{id}")
      send_message(view, "go")
      _ = wait_for(id, &match?({:assistant_delta, _}, &1))
      view |> element("#cancel") |> render_click()
      _ = wait_for(id, &match?({:state, :idle}, &1))
      html = render(view)
      assert has_element?(view, "#banner")
      assert html =~ "interrupted"
      assert html =~ "partial"
      refute html =~ "never"
      [_, interrupted] = Sessions.history(id)
      assert interrupted.parts["interrupted"] == true

      view |> element("#banner button", "Retry") |> render_click()
      _ = wait_for(id, &match?({:assistant_message, _}, &1))
      refute has_element?(view, "#banner")

      assert Enum.map(Sessions.history(id), & &1.role) == [
               "user",
               "assistant",
               "user",
               "assistant"
             ]

      assert render(view) =~ "again again"
    end

    test "Esc reaches cancel through the Shortcuts hook", %{conn: conn, id: id} do
      Fake.script([{:text_delta, "p "}, {:sleep, 3_000}, {:done, :stop}])
      {:ok, view, _} = live(conn, ~p"/s/#{id}")
      send_message(view, "go")
      _ = wait_for(id, &match?({:assistant_delta, _}, &1))
      render_hook(view, "cancel", %{})
      _ = wait_for(id, &match?({:turn_interrupted, _}, &1))
      assert has_element?(view, "#banner")
    end
  end

  describe "the Session dies under the page (AC4, the test half)" do
    test "the banner appears without a reload, the page stays usable, the next message works", %{
      conn: conn,
      id: id
    } do
      # Long enough for a draft row to be written (500 ms) before the kill.
      Fake.scripts([
        [
          {:text_delta, "before "},
          {:sleep, 700},
          {:text_delta, "x"},
          {:sleep, 3_000},
          {:done, :stop}
        ],
        script_deltas(2, "after ")
      ])

      {:ok, view, _} = live(conn, ~p"/s/#{id}")
      send_message(view, "go")
      _ = wait_for(id, fn e -> e == {:assistant_delta, "x"} end)
      pid = Sessions.whereis(id)
      Process.exit(pid, :kill)

      # The new incarnation enters idle (its first broadcast) and then rehydrates the draft.
      _ = wait_for(id, &match?({:turn_interrupted, _}, &1))
      assert Process.alive?(view.pid)
      html = render(view)
      assert has_element?(view, "#banner")
      assert html =~ "before"
      assert has_element?(view, "#status[data-status=idle]")
      refute has_element?(view, "#draft")
      assert Sessions.whereis(id) != pid

      send_message(view, "again")
      _ = wait_for(id, &match?({:assistant_message, _}, &1))
      assert render(view) =~ "after after"

      assert Enum.map(Sessions.history(id), & &1.role) == [
               "user",
               "assistant",
               "user",
               "assistant"
             ]
    end
  end

  describe "a remount mid-stream (AC5)" do
    test "history comes from the database, the draft so far from the process; nothing doubles or goes missing",
         %{conn: conn, id: id} do
      Factory.message!(id, %{role: "user", content: "earlier question"})
      Factory.message!(id, %{role: "assistant", content: "earlier answer"})

      Fake.script([
        {:text_delta, "one "},
        {:text_delta, "two "},
        {:sleep, 800},
        {:text_delta, "three"},
        {:done, :stop}
      ])

      {:ok, first, _} = live(conn, ~p"/s/#{id}")
      send_message(first, "go")

      _ =
        wait_for(id, fn e ->
          e == {:assistant_delta, "one two "} or e == {:assistant_delta, "two "}
        end)

      # The reload: a second page for the same session, mounted while the turn is in flight.
      {:ok, second, html} = live(conn, ~p"/s/#{id}")
      assert html =~ "earlier question"
      assert html =~ "earlier answer"
      assert html =~ "one two"
      assert has_element?(second, "#draft")

      _ = wait_for(id, &match?({:state, :idle}, &1))
      html = render(second)
      assert length(String.split(html, "one two three")) - 1 == 1
      refute has_element?(second, "#draft")
      rows = Sessions.history(id)
      assert length(rows) == 4

      for row <- rows do
        assert has_element?(second, "#message-#{row.id}"),
               "row seq #{row.seq} missing after remount"

        assert has_element?(first, "#message-#{row.id}"),
               "row seq #{row.seq} missing on the first page"
      end

      assert length(Regex.scan(~r/id="message-[0-9a-f-]+" class=/, html)) == 4
    end
  end

  describe "the model picker (AC6)" do
    test "changes sessions.model and the next turn uses it", %{conn: conn, id: id} do
      Fake.script(script_deltas(1, "ok"))
      {:ok, view, _} = live(conn, ~p"/s/#{id}")
      assert has_element?(view, "#model-picker option[selected][value='fake:chat']")

      view |> form("#model-picker", %{"model" => "mock:chat"}) |> render_change()
      assert Sessions.get_session(id).model == "mock:chat"
      assert has_element?(view, "#model-picker option[selected][value='mock:chat']")

      # Back to the fake, which records the request it was given.
      view |> form("#model-picker", %{"model" => "fake:embed"}) |> render_change()
      send_message(view, "which model?")
      _ = wait_for(id, &match?({:assistant_message, _}, &1))
      assert Fake.last_request().model == "fake:embed"
    end
  end

  describe "render count (AC7)" do
    test "1,000 deltas in well under a second render the page at most 25 times", %{
      conn: conn,
      id: id
    } do
      Fake.script(script_deltas(1_000, "y"))
      {:ok, view, _} = live(conn, ~p"/s/#{id}")
      test_pid = self()
      view_pid = view.pid

      :telemetry.attach(
        "ac7-#{id}",
        [:phoenix, :live_view, :render, :stop],
        fn _event, _measure, _meta, _config ->
          if self() == view_pid, do: send(test_pid, :rendered)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("ac7-#{id}") end)

      send_message(view, "go")
      _ = wait_for(id, &match?({:state, :idle}, &1))
      html = render(view)
      renders = count(:rendered, 0)
      IO.puts("\nAC7: #{renders} renders of the page for 1,000 deltas")
      assert renders <= 25, "#{renders} renders"
      assert html =~ String.duplicate("y", 1_000)
    end

    defp count(msg, n) do
      receive do
        ^msg -> count(msg, n + 1)
      after
        0 -> n
      end
    end
  end
end
