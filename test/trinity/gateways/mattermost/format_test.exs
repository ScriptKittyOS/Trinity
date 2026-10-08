# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.FormatTest do
  @moduledoc """
  Slice 072, AC2: posts are cut to the size the server advertises, as the server counts it.

  The property is the claim: for any text and any limit, no post is longer than the limit in code
  points. The generator leans on what breaks a grapheme-counting chunker: code fences (the shared
  chunker re-opens one after measuring) and graphemes of several code points. The end-to-end cases
  read `MaxPostSize` from a server and show the cut following it.
  """
  use Trinity.SessionCase
  use ExUnitProperties

  import Trinity.Gateways.Mattermost.TestHelpers

  alias Trinity.Gateways.{Mattermost, Router}
  alias Trinity.Gateways.Mattermost.{FakeServer, Format, State}
  alias Trinity.LLM.Providers.Fake

  # A flag (two code points), a family (seven), a combining accent (two), and plain words.
  @pieces ["word", "longerword", " ", "\n", "\n\n", "```", "```elixir\n", "🇺🇳", "👨‍👩‍👧‍👦", "é", "x"]

  defp text_gen do
    @pieces
    |> StreamData.member_of()
    |> StreamData.list_of(max_length: 400)
    |> StreamData.map(&Enum.join/1)
  end

  defp caps(max),
    do: %{markdown: true, images: false, buttons: false, edits: true, max_length: max}

  property "no post is longer than the limit, in code points, whatever the text" do
    check all(text <- text_gen(), max <- StreamData.integer(12..300)) do
      for post <- Format.format(text, caps(max)) do
        assert Format.codepoints(post) <= max,
               "#{Format.codepoints(post)} code points against a limit of #{max}: #{inspect(post)}"
      end
    end
  end

  property "a cut never splits a grapheme unless the grapheme alone is over the limit" do
    check all(text <- text_gen(), max <- StreamData.integer(12..300)) do
      for post <- Format.format(text, caps(max)) do
        assert String.valid?(post)
      end
    end
  end

  test "a single grapheme longer than the limit is the one case cut at code points" do
    family = "👨‍👩‍👧‍👦"
    assert Format.codepoints(family) == 7
    assert Format.fit(family, 3) |> Enum.all?(&(Format.codepoints(&1) <= 3))
    assert Format.fit(family, 3) |> Enum.join() == family
  end

  test "an approval's text names the command a Mattermost user can type" do
    approval = %Trinity.Permissions.Approval{
      id: "0123456789abcdef",
      tool: "write_note",
      risk: "write",
      args: %{"path" => "notes/a.md"}
    }

    {:message, text} = Format.render_approval(approval, caps(4_000))
    assert text =~ "/trinity approve 01234567"
    assert text =~ "/trinity deny 01234567"
    refute text =~ "with /approve"
  end

  describe "the server's own limit" do
    setup do
      start_supervised!(Router)
      pair_tester!()
      :ok
    end

    defp reply_to_dm(server, text) do
      Fake.scripts([
        [{:text_delta, text}, {:usage, %{input_tokens: 1, output_tokens: 1}}, {:done, :stop}]
      ])

      FakeServer.push(server, hd(FakeServer.frames("posted")))
    end

    test "AC2: a server advertising 120 gets posts of at most 120 code points, and the whole answer" do
      server = start_adapter!(max_post_size: "120")
      assert State.max_post_size() == 120
      assert Mattermost.capabilities().max_length == 120

      answer = Enum.map_join(1..60, " ", &"word#{&1}")
      reply_to_dm(server, answer)
      await_shown(server, "word60")

      posts = server |> FakeServer.created() |> Enum.map(& &1["message"])
      assert length(posts) > 1
      assert Enum.all?(posts, &(Format.codepoints(&1) <= 120))

      # And every post as it stands after the stream's edits.
      assert server
             |> FakeServer.posts()
             |> Map.values()
             |> Enum.all?(&(Format.codepoints(&1) <= 120))

      # Nothing was lost to the cut: every word arrived, in order.
      words = server |> FakeServer.posts() |> Map.values() |> Enum.join(" ") |> String.split()
      assert Enum.filter(words, &String.starts_with?(&1, "word")) |> length() == 60
    end

    test "AC2: the same answer to a server advertising 16383 is one post" do
      server = start_adapter!(max_post_size: "16383")
      assert Mattermost.capabilities().max_length == 16_383

      reply_to_dm(server, Enum.map_join(1..60, " ", &"word#{&1}"))
      await_shown(server, "word60")
      assert [_one] = FakeServer.created(server)
    end

    test "the limit is not a constant of this module: it is whatever the server last said" do
      refute State.fallback_max_post_size() in [120, 16_383]
      server = start_adapter!(max_post_size: "777")
      assert Mattermost.capabilities().max_length == 777

      assert FakeServer.requests(server)
             |> Enum.any?(&match?({"GET", "/api/v4/config/client", _}, &1))
    end
  end
end
