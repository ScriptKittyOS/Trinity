# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.AdapterTest do
  @moduledoc """
  Slice 072, AC2 and AC5, end to end: frames recorded from a real server are pushed by
  `FakeServer` to the adapter's socket, through the real router and a real session answered by the
  fake provider, and back to the server as posts and edits.

  AC2: which conversation (and so which session) each recorded post belongs to, and that the
  reply streams into one post by editing it. AC5: the mapping against the recorded frames, and a
  consumer killed mid-run that reconnects, is replayed what it already handled, and answers it
  once.
  """
  use Trinity.SessionCase

  import Trinity.Gateways.Mattermost.TestHelpers

  alias Trinity.Gateways.{Mattermost, Router}
  alias Trinity.Gateways.Mattermost.{FakeServer, Socket}
  alias Trinity.LLM.Providers.Fake

  # The recorded frames, by what they are (fixtures.json, captured 2026-10-08).
  defp frame(n), do: Enum.at(FakeServer.frames("posted"), n)
  defp dm_top, do: frame(0)
  defp dm_thread_reply, do: frame(1)
  defp channel_mention, do: frame(2)
  defp channel_thread_reply, do: frame(3)
  defp channel_chatter, do: frame(4)
  defp dm_with_file, do: frame(5)
  defp own_post, do: frame(6)
  defp system_post, do: frame(7)

  defp post_of(raw), do: raw |> Jason.decode!() |> get_in(["data", "post"]) |> Jason.decode!()

  setup do
    start_supervised!(Router)
    pair_tester!()
    :ok
  end

  defp streamed(text, pause \\ 0) do
    deltas =
      text
      |> String.split(" ")
      |> Enum.flat_map(&[{:text_delta, &1 <> " "}, {:sleep, pause}])

    deltas ++ [{:usage, %{input_tokens: 3, output_tokens: 3}}, {:done, :stop}]
  end

  test "AC2: a direct message is answered in the DM, streamed into one post by editing it" do
    server = start_adapter!()
    Fake.scripts([streamed("one two three four five six", 300)])

    FakeServer.push(server, dm_top())
    await_shown(server, "one two three four five six")

    dm = post_of(dm_top())["channel_id"]

    # One post, then edits to it: the stream, not a post per delta.
    created = FakeServer.created(server)
    assert [%{"channel_id" => ^dm, "root_id" => ""}] = created

    edits = for {"PUT", "/api/v4/posts/" <> _, _} <- FakeServer.requests(server), do: :edit
    assert edits != [], "the reply was posted once and never edited, so it did not stream"

    # A DM's top level is one conversation and one session, which came from this channel.
    session_id = Router.session_of(Mattermost, dm)
    assert %{origin: "mattermost"} = Sessions.get_session(session_id)
  end

  test "AC2: a reply inside a DM thread is a conversation of its own, answered in that thread" do
    server = start_adapter!()
    Fake.scripts([streamed("threaded answer")])

    FakeServer.push(server, dm_thread_reply())
    await_shown(server, "threaded answer")

    post = post_of(dm_thread_reply())
    assert [%{"root_id" => root}] = FakeServer.created(server)
    assert root == post["root_id"]
    assert Router.session_of(Mattermost, post["channel_id"] <> ":" <> root)
    assert Router.session_of(Mattermost, post["channel_id"]) == nil
  end

  test "AC2: a channel mention starts a thread; a reply there continues it unmentioned; chatter is not read" do
    server = start_adapter!()
    Fake.scripts([streamed("first in the thread"), streamed("second in the thread")])

    FakeServer.push(server, channel_mention())
    await_shown(server, "first in the thread")

    mention = post_of(channel_mention())
    thread = mention["channel_id"] <> ":" <> mention["id"]
    session_id = Router.session_of(Mattermost, thread)
    assert session_id

    # The mention is taken out of what the session is told.
    assert [%{content: "what is on the list today?"} | _] =
             Enum.filter(Sessions.history(session_id), &(&1.role == "user"))

    FakeServer.push(server, channel_thread_reply())
    await_shown(server, "second in the thread")
    assert Router.session_of(Mattermost, thread) == session_id

    # Both answers went into the thread, under the mention.
    assert Enum.all?(FakeServer.created(server), &(&1["root_id"] == mention["id"]))

    # Talk in the channel that does not mention the bot is not read: no call, no post, no session.
    calls = Fake.calls()
    before = FakeServer.created(server)
    FakeServer.push(server, channel_chatter())
    chatter = post_of(channel_chatter())
    Process.sleep(300)
    assert Fake.calls() == calls
    assert FakeServer.created(server) == before
    assert Router.session_of(Mattermost, chatter["channel_id"] <> ":" <> chatter["id"]) == nil
  end

  test "AC5: the bot's own post and a system post are never answered" do
    server = start_adapter!()

    FakeServer.push(server, own_post())
    FakeServer.push(server, system_post())
    Process.sleep(300)

    assert Fake.calls() == 0
    assert FakeServer.created(server) == []
  end

  test "AC5: a file is not carried, and the paired sender is told so" do
    server = start_adapter!()
    Fake.scripts([streamed("I read your text")])

    FakeServer.push(server, dm_with_file())
    await_shown(server, "I read your text")
    await_shown(server, "cannot read files")
  end

  test "AC5: a consumer killed mid-run reconnects, resumes, and answers a replayed post once" do
    server = start_adapter!()
    Fake.scripts([streamed("answer to the first"), streamed("answer to the second")])

    FakeServer.push(server, dm_top())
    await_shown(server, "answer to the first")
    assert Fake.calls() == 1

    # The next resume replays from the very first event, so it includes the post already
    # answered: the overlap a consumer that died after handling and before acknowledging sees.
    FakeServer.replay_from(server, 1)
    old = Process.whereis(Socket)
    Process.exit(old, :kill)

    await(fn -> (pid = Process.whereis(Socket)) && pid != old end, "the socket to be restarted")
    await(fn -> length(FakeServer.connects(server)) == 2 end, "the socket to reconnect", 15_000)

    # It resumed rather than starting over: the server's own connection id and the next number.
    [_first, resumed] = FakeServer.connects(server)
    assert resumed =~ "connection_id="
    assert resumed =~ "sequence_number="

    # A new post after the replay. The socket hands posts to the router one at a time and in
    # order, so once this one has been answered the replay has been read; and once every session
    # is idle again, any turn the replay started has finished and been counted. Waiting on the
    # answer's text alone is not enough: under a planted double-handling the replay is answered
    # with the second script, and a wait on that text passes before the third call is made (seen
    # once while demonstrating this test red; NOTES, "Red evidence", R2).
    await(fn -> FakeServer.sockets(server) != [] end, "the server to see the new socket")
    FakeServer.push(server, dm_thread_reply())
    thread_root = post_of(dm_thread_reply())["root_id"]

    await(
      fn -> Enum.any?(FakeServer.created(server), &(&1["root_id"] == thread_root)) end,
      "the thread reply to be answered in its thread"
    )

    await(&all_idle?/0, "every session to be idle")

    # The model was asked twice, once per post, and the DM's top level was answered once.
    assert Fake.calls() == 2
    top_level = Enum.filter(FakeServer.created(server), &(&1["root_id"] == ""))
    assert length(top_level) == 1
  end

  defp all_idle? do
    Enum.all?(Sessions.list_sessions(), fn session ->
      case Sessions.state(session.id) do
        %{state: :idle} -> true
        {:error, :not_running} -> true
        _ -> false
      end
    end)
  end

  test "a conversation that is not a server id is refused before any request is made" do
    server = start_adapter!()

    for bad <- ["../../users/me", "abc", "pxejam7xm3njbrsuo4zh6d897w:../x", nil, 42] do
      assert {:error, :bad_conversation} = Mattermost.deliver(bad, {:message, "x"})
    end

    assert {:error, :bad_id} =
             Mattermost.deliver(post_of(dm_top())["channel_id"], {:edit, "../x", "y"})

    assert FakeServer.requests(server) |> Enum.filter(&match?({"POST", "/api/v4/posts", _}, &1)) ==
             []
  end
end
