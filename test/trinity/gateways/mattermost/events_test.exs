# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.EventsTest do
  @moduledoc """
  Slice 072, AC5: every frame a real server sent the bot, read. The population is the recorded
  capture (`test/support/mattermost/fixtures.json`), not a list written here: each frame in it is
  classified, and the test fails on a frame it has no expectation for, so a recapture that brings
  a new kind of frame cannot pass unread.
  """
  use ExUnit.Case, async: true

  alias Trinity.Gateways.Mattermost.{Events, FakeServer}

  @me FakeServer.fixtures()["rest"]["users_me"]
  @facts %{bot_user_id: @me["id"], bot_username: @me["username"], max_post_size: 16_383}
  @tester "yuadbo77878m8myazrtkfyi5pw"
  @dm "rebfe39yetygpyn11ma3gbairy"
  @ops "pxejam7xm3njbrsuo4zh6d897w"

  defp all_frames, do: FakeServer.fixtures()["frames"] ++ FakeServer.fixtures()["system_frames"]
  defp read(frame, following \\ fn _ -> false end), do: Events.read(frame, @facts, following)

  test "the capture is what the tests below assume it is" do
    assert @me["is_bot"] == true
    assert length(all_frames()) == 15
  end

  test "every recorded frame is classified, and nothing in the capture is unreadable" do
    for frame <- all_frames() do
      result = read(frame)
      refute match?({:unreadable, _}, result), "unreadable: #{frame}"
    end
  end

  test "the handshake: hello with the connection id, and the authentication reply" do
    [hello, auth | _] = FakeServer.fixtures()["frames"]
    assert {:hello, id, 0} = read(hello)
    assert id =~ ~r/\A[a-z0-9]{26}\z/
    assert {:auth, :ok} = read(auth)
  end

  test "posts, by what they are, against the recorded frames" do
    results = for frame <- FakeServer.frames("posted"), do: read(frame)

    assert [
             {:post, _, dm_top},
             {:post, _, dm_reply},
             {:post, _, mention},
             {:event, _, :not_addressed},
             {:event, _, :not_addressed},
             {:post, _, with_file},
             {:event, _, :own_post},
             {:event, _, :system_post}
           ] = results

    assert %{conversation: @dm, user_id: @tester, text: "hello from a direct message"} = dm_top
    assert dm_top.display_name == "tester"
    assert dm_top.follow == nil

    assert %{conversation: @dm <> ":" <> root, text: "a reply inside a DM thread"} = dm_reply
    assert root == dm_top.post_id

    # A mention starts a thread named by the post itself, and the mention leaves the text.
    assert mention.conversation == @ops <> ":" <> mention.post_id
    assert mention.text == "what is on the list today?"
    assert mention.follow == mention.conversation

    assert with_file.files == 1
    assert with_file.text == "here is a file"
  end

  test "a reply in a thread the bot follows is read without a mention; chatter never is" do
    [_, _, mention, thread_reply, chatter | _] = FakeServer.frames("posted")
    {:post, _, %{follow: thread}} = read(mention)

    following = &(&1 == thread)

    assert {:post, _, %{conversation: ^thread, text: "and tomorrow?"}} =
             read(thread_reply, following)

    assert {:event, _, :not_addressed} = read(chatter, following)
  end

  test "every numbered event advances the sequence, posts or not" do
    seqs =
      for frame <- FakeServer.fixtures()["frames"],
          seq =
            (case read(frame) do
               {:post, seq, _} -> seq
               {:event, seq, _} -> seq
               {:hello, _, seq} -> seq
               _ -> nil
             end),
          is_integer(seq),
          do: seq

    assert seqs == Enum.sort(seqs)
    assert seqs == Enum.to_list(0..12)
  end

  test "before the server's facts are known, a post is not read against nothing" do
    [dm_top | _] = FakeServer.frames("posted")
    assert {:event, _, :no_facts_yet} = Events.read(dm_top, nil, fn _ -> false end)
  end

  test "a frame that is not JSON, or not an event, is said to be so rather than raised on" do
    assert {:unreadable, :not_json} = read("{")
    assert {:event, nil, :not_an_event} = read(~s({"hello": 1}))
  end

  test "a post carrying a malformed id is not read" do
    [dm_top | _] = FakeServer.frames("posted")
    decoded = Jason.decode!(dm_top)
    post = decoded["data"]["post"] |> Jason.decode!() |> Map.put("channel_id", "../../x")
    frame = put_in(decoded, ["data", "post"], Jason.encode!(post)) |> Jason.encode!()
    assert {:event, _, :unreadable_post} = read(frame)
  end
end
