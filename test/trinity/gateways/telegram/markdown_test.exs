# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.MarkdownTest do
  @moduledoc """
  Slice 071, AC4: formatting, escaping and chunking with tricky markdown (code blocks,
  underscores, links), checked against the MarkdownV2 parse rules in
  `Trinity.FakeTelegram.MarkdownV2`, the same checker the fake Bot API refuses a message with.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.FakeTelegram.MarkdownV2
  alias Trinity.Gateways.Telegram
  alias Trinity.Gateways.Telegram.Markdown

  @caps Telegram.capabilities()

  defp v2(text), do: Markdown.to_markdown_v2(text)

  describe "the checker discriminates" do
    test "it refuses what Telegram refuses" do
      assert {:error, {:unescaped, ".", _}} = MarkdownV2.check("a.b")
      assert {:error, {:unclosed, [:bold], _}} = MarkdownV2.check("*open")
      assert {:error, {:unescaped, ")", _}} = MarkdownV2.check("[a](http://x.y/a)b)")
      assert {:error, {:unescaped, ">", _}} = MarkdownV2.check("a > b")
      assert {:error, {:improper_nesting, :bold, _}} = MarkdownV2.check("*a _b *c* d_ e*")
      assert :ok = MarkdownV2.check("*bold* _it_ `co\\`de` [l](http://x\\)y) \\. \\>")
      assert :ok = MarkdownV2.check(">quote\n```elixir\nIO.puts(\"*_\")\n```")
    end

    test "the plain-text formatter the console uses is not MarkdownV2, which is why this module exists" do
      text = "Done. See `mix test` (it passed) and file_name.ex!"
      [chunk] = Trinity.Gateways.Format.format(text, %{markdown: true, max_length: 4096})
      assert {:error, _} = MarkdownV2.check(chunk)
      assert :ok = MarkdownV2.check(v2(text))
    end
  end

  describe "AC4: escaping" do
    test "every reserved character outside an entity is escaped" do
      assert v2("_*[]()~`>#+-=|{}.!\\") ==
               "\\_\\*\\[\\]\\(\\)\\~\\`\\>\\#\\+\\-\\=\\|\\{\\}\\.\\!\\\\"
    end

    test "underscores inside a word are characters, not italics" do
      assert v2("call snake_case_name and __init__ here") ==
               "call snake\\_case\\_name and *init* here"

      assert v2("my_var_") == "my\\_var\\_"
      assert v2("_real italic_ then x_y") == "_real italic_ then x\\_y"
    end

    test "a markdown backslash escape is the character, escaped once" do
      assert v2("\\*not bold\\*") == "\\*not bold\\*"
      assert v2("1\\. not a list") == "1\\. not a list"
    end

    test "text that is not UTF-8 becomes the replacement character, not a refused message" do
      assert :ok = MarkdownV2.check(v2(<<"ok ", 0xFF, " fine.">>))
    end
  end

  describe "AC4: entities" do
    test "bold, italic, strike and inline code" do
      assert v2("**bold** *it* ~~gone~~ `x.y`") == "*bold* _it_ ~gone~ `x.y`"
    end

    test "inline code escapes only the backtick and the backslash" do
      assert v2("run `a\\b` and ``a`b``") == "run `a\\\\b` and `a\\`b`"
    end

    test "a fenced block keeps its language and escapes only ` and \\ inside" do
      text = "Before:\n```elixir\ndef f(x), do: x * 2 # ok.\nIO.puts(\"a\\\\b `c`\")\n```\nAfter."

      assert v2(text) ==
               "Before:\n```elixir\ndef f(x), do: x * 2 # ok.\nIO.puts(\"a\\\\\\\\b \\`c\\`\")\n```\nAfter\\."

      assert :ok = MarkdownV2.check(v2(text))
    end

    test "a fence that never closes is still code, and is closed" do
      assert v2("```\nhalf a stream (") == "```\nhalf a stream (\n```"
    end

    test "a language that is not a plain word is dropped rather than risked" do
      assert v2("```c++ {x}\nint a;\n```") == "```\nint a;\n```"
    end

    test "links: the label is escaped, the URL escapes ) and \\, a paren pair in the URL survives" do
      assert v2("[the docs](https://example.com/a_b.html)") ==
               "[the docs](https://example.com/a_b.html)"

      assert v2("see [Foo (bar)](https://en.wikipedia.org/wiki/Foo_(bar)).") ==
               "see [Foo \\(bar\\)](https://en.wikipedia.org/wiki/Foo_(bar\\))\\."

      assert :ok =
               MarkdownV2.check(v2("see [Foo (bar)](https://en.wikipedia.org/wiki/Foo_(bar))."))
    end

    test "a link to anything but http, https, tg or mailto stays text" do
      assert v2("[x](javascript:alert(1))") == "\\[x\\]\\(javascript:alert\\(1\\)\\)"
      assert v2("[x](relative/path)") == "\\[x\\]\\(relative/path\\)"
    end

    test "headings are bold, lists are bullets, numbers keep an escaped dot, quotes are quotes" do
      text = "# Title **here**\n- one\n* two\n3. three\n> said _so_\n---"
      assert v2(text) == "*Title here*\n• one\n• two\n3\\. three\n>said _so_\n──────────"
      assert :ok = MarkdownV2.check(v2(text))
    end

    test "two entities of a kind side by side do not become an underline" do
      out = v2("*a*_b_")
      assert :ok = MarkdownV2.check(out)
      refute out =~ "__"
    end
  end

  describe "AC4: half-written markdown, as a stream delivers it" do
    test "an entity that is not closed yet is escaped text" do
      for partial <- ["**bol", "*it", "`co", "[link](https://exa", "~~str", "_x", "```py\nx = 1"] do
        assert :ok = MarkdownV2.check(v2(partial)), "#{inspect(partial)} -> #{v2(partial)}"
      end

      assert v2("**bol") == "\\*\\*bol"
      assert v2("[link](https://exa") == "\\[link\\]\\(https://exa"
    end
  end

  describe "AC4: chunking at 4096" do
    test "a long answer splits into chunks that each fit and each parse" do
      paragraph = "A sentence with **bold**, `code` and a [link](https://example.com). "
      text = String.duplicate(paragraph, 200)
      chunks = Telegram.format(text, @caps)

      assert length(chunks) > 1

      for chunk <- chunks do
        out = v2(chunk)
        assert Markdown.utf16_length(out) <= 4096
        assert :ok = MarkdownV2.check(out)
      end
    end

    test "escaping can double a text's length, and the chunks are sized after it" do
      text = String.duplicate(".", 6000)
      chunks = Telegram.format(text, @caps)
      assert Enum.all?(chunks, &(Markdown.utf16_length(v2(&1)) <= 4096))
      assert Enum.join(chunks) == text
    end

    test "emoji count two units each, as Telegram counts them" do
      assert Markdown.utf16_length("a😀") == 3
      text = String.duplicate("😀", 3000)
      chunks = Telegram.format(text, @caps)
      assert Enum.all?(chunks, &(Markdown.utf16_length(v2(&1)) <= 4096))
      assert Enum.join(chunks) == text
    end

    test "a code block split across chunks is closed and reopened, and each chunk parses" do
      code = Enum.map_join(1..900, "\n", &"line_#{&1} = #{&1} * 2.0")
      text = "Here:\n```python\n" <> code <> "\n```\nDone."
      chunks = Telegram.format(text, @caps)
      assert length(chunks) > 1

      for chunk <- chunks do
        out = v2(chunk)
        assert :ok = MarkdownV2.check(out)
        assert Markdown.utf16_length(out) <= 4096
      end
    end
  end

  describe "AC4: the property, over generated input" do
    # - + = | { } . ! > \\ \n \n\n https://x.y/(z) word snake_case 😀 é)
    @pieces ~w(** * __ _ ~~ ` ``` [ ] ( )
    @pieces @pieces ++ [" ", "  ", "[a](https://e.x/p_(q))", "1. ", "- ", "> ", "```py\n"]

    property "whatever the markdown, the output parses as MarkdownV2" do
      check all(parts <- list_of(member_of(@pieces), max_length: 60), max_runs: 1_000) do
        text = Enum.join(parts)
        out = v2(text)
        assert :ok == MarkdownV2.check(out), "input #{inspect(text)}\noutput #{inspect(out)}"
      end
    end

    property "whatever the markdown, every chunk fits 4096 units and parses" do
      check all(
              parts <- list_of(member_of(@pieces), min_length: 1, max_length: 40),
              times <- integer(1..400),
              max_runs: 60
            ) do
        text = parts |> Enum.join() |> String.duplicate(times)

        for chunk <- Telegram.format(text, @caps) do
          out = v2(chunk)
          assert Markdown.utf16_length(out) <= 4096
          assert :ok == MarkdownV2.check(out), "chunk #{inspect(chunk)}"
        end
      end
    end
  end
end
