# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Markdown do
  @moduledoc """
  The markdown a model writes, as Telegram's MarkdownV2 (slice 071).

  MarkdownV2 is strict where model markdown is loose: eighteen punctuation characters must be
  escaped wherever they are not markup, an entity left open is a parse error, and a parse error is
  the whole message refused (`400 Bad Request: can't parse entities`). A streamed answer is
  half-written markdown by construction, so the rule this module holds is that **its output parses
  whatever its input is**: an entity is emitted only when both its delimiters are present and its
  content is not empty, and everything else is escaped as text. A half-streamed `**bol` arrives as
  the literal characters, and becomes bold on the edit that closes it.

  What is translated: fenced code (a `pre` entity, its language kept when it is a plain word),
  inline code, `**bold**` and `__bold__`, `*italic*` and `_italic_` (an underscore inside a word,
  as in `snake_case`, is a character and not markup), `~~strike~~`, `[text](url)` for `http`,
  `https`, `tg` and `mailto` URLs (anything else stays text), headings (bold), block quotes, list
  markers (a bullet, or the number with its dot escaped) and rules. Inside `pre` and `code` only
  `` ` `` and `\\` are escaped; inside a link's URL only `)` and `\\`, which is MarkdownV2's own rule.

  Two entities of the same kind side by side (`_a__b_`) would read as underline, which Telegram's
  parser takes greedily; the second is written as plain text instead, which loses one emphasis and
  never a message.

  Nothing here is a markdown renderer and nothing tries to be: tables, footnotes and HTML are text.
  """

  @reserved ~c"_*[]()~`>#+-=|{}.!\\"
  @ascii_punct ~c"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
  @schemes ~w(http https tg mailto)
  @rule "──────────"

  @doc "Markdown as MarkdownV2 text that Telegram's parser accepts, whatever the input."
  @spec to_markdown_v2(String.t()) :: String.t()
  def to_markdown_v2(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> blocks([])
    |> Enum.map_join("\n", &render_block/1)
  end

  @doc "A character escaped for MarkdownV2 text, when it needs it."
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text) do
    for <<c::utf8 <- text>>, into: "", do: escape_char(c)
  end

  @doc """
  The length Telegram counts: UTF-16 code units, so a character outside the Basic Multilingual
  Plane (most emoji) counts two.
  """
  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(text) when is_binary(text) do
    for <<c::utf8 <- text>>, reduce: 0, do: (n -> n + if(c > 0xFFFF, do: 2, else: 1))
  end

  ## Blocks: fenced code, and lines

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest], acc) do
    case Regex.run(~r/^ {0,3}```([^`]*)$/, line) do
      [_, info] ->
        {body, rest} = until_fence(rest, [])
        blocks(rest, [{:code, language(info), body} | acc])

      nil ->
        blocks(rest, [{:line, line} | acc])
    end
  end

  # An unclosed fence runs to the end of the text and is closed here: what follows an opening
  # fence is code, and a stream that has not reached the closing fence yet is still code.
  defp until_fence([], acc), do: {Enum.reverse(acc), []}

  defp until_fence([line | rest], acc) do
    if Regex.match?(~r/^ {0,3}```\s*$/, line),
      do: {Enum.reverse(acc), rest},
      else: until_fence(rest, [line | acc])
  end

  defp language(info) do
    case info |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [word | _] -> if Regex.match?(~r/^[A-Za-z0-9]{1,32}$/, word), do: word, else: ""
      _ -> ""
    end
  end

  defp render_block({:code, lang, body}) do
    case Enum.join(body, "\n") do
      "" -> ""
      code -> "```" <> lang <> "\n" <> escape_code(code) <> "\n```"
    end
  end

  defp render_block({:line, line}) do
    cond do
      match = Regex.run(~r/^ {0,3}[#]{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/, line) ->
        line_entity(Enum.at(match, 1), "*", MapSet.new([:bold]))

      Regex.match?(~r/^ {0,3}[#]{1,6}[ \t]*$/, line) ->
        ""

      Regex.match?(~r/^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/, line) ->
        @rule

      match = Regex.run(~r/^ {0,3}>[ \t]?(.*)$/, line) ->
        quote_line(Enum.at(match, 1))

      match = Regex.run(~r/^([ \t]*)[-*+][ \t]+(.*)$/, line) ->
        [_, indent, rest] = match
        indent <> "• " <> inline(rest, MapSet.new())

      match = Regex.run(~r/^([ \t]*)(\d{1,9})([.)])[ \t]+(.*)$/, line) ->
        [_, indent, n, delim, rest] = match
        indent <> n <> "\\" <> delim <> " " <> inline(rest, MapSet.new())

      true ->
        inline(line, MapSet.new())
    end
  end

  defp line_entity(content, delim, ctx) do
    case inline(content, ctx) do
      "" -> ""
      rendered -> delim <> rendered <> delim
    end
  end

  defp quote_line(rest) do
    case inline(rest, MapSet.new()) do
      "" -> ""
      rendered -> ">" <> rendered
    end
  end

  ## Inline

  # `ctx` holds the entity kinds already open around this text: one kind is never nested in
  # itself, so the markers of an inner one are dropped and its text kept.
  defp inline(text, ctx), do: text |> scan(ctx, nil, nil, []) |> IO.iodata_to_binary()

  # `prev` is the source character before this point (for the word-boundary rule on `_`);
  # `last` is the kind of entity just emitted, if the last thing emitted was one.
  defp scan("", _ctx, _prev, _last, acc), do: Enum.reverse(acc)

  defp scan(<<"\\", c::utf8, rest::binary>>, ctx, _prev, _last, acc) when c in @ascii_punct,
    do: scan(rest, ctx, c, nil, [escape_char(c) | acc])

  defp scan(<<"`", _::binary>> = text, ctx, _prev, _last, acc) do
    case Regex.run(~r/\A(`+)(?!`)(.+?)(?<!`)\1(?!`)/u, text) do
      [whole, _ticks, inner] ->
        rest = binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole))
        scan(rest, ctx, ?`, :code, ["`" <> escape_code(inner) <> "`" | acc])

      nil ->
        {ticks, rest} = take_run(text, ?`)
        scan(rest, ctx, ?`, nil, [String.duplicate("\\`", byte_size(ticks)) | acc])
    end
  end

  defp scan(<<"**", rest::binary>>, ctx, _prev, last, acc),
    do: pair(rest, "**", :bold, "*", ctx, last, acc)

  defp scan(<<"~~", rest::binary>>, ctx, _prev, last, acc),
    do: pair(rest, "~~", :strike, "~", ctx, last, acc)

  defp scan(<<"__", rest::binary>>, ctx, prev, last, acc) do
    if word?(prev),
      do: scan(rest, ctx, ?_, nil, ["\\_\\_" | acc]),
      else: pair(rest, "__", :bold, "*", ctx, last, acc, &closes_at_word_end?/2)
  end

  defp scan(<<"*", rest::binary>>, ctx, _prev, last, acc),
    do: pair(rest, "*", :italic, "_", ctx, last, acc)

  defp scan(<<"_", rest::binary>>, ctx, prev, last, acc) do
    if word?(prev),
      do: scan(rest, ctx, ?_, nil, ["\\_" | acc]),
      else: pair(rest, "_", :italic, "_", ctx, last, acc, &closes_at_word_end?/2)
  end

  defp scan(<<"![", _::binary>> = text, ctx, prev, last, acc) do
    case link(binary_part(text, 1, byte_size(text) - 1), ctx) do
      {:ok, rendered, rest} -> scan(rest, ctx, ?), :link, [rendered | acc])
      :error -> plain(text, ctx, prev, last, acc)
    end
  end

  defp scan(<<"[", _::binary>> = text, ctx, prev, last, acc) do
    case link(text, ctx) do
      {:ok, rendered, rest} -> scan(rest, ctx, ?), :link, [rendered | acc])
      :error -> plain(text, ctx, prev, last, acc)
    end
  end

  defp scan(text, ctx, prev, last, acc), do: plain(text, ctx, prev, last, acc)

  defp plain(<<c::utf8, rest::binary>>, ctx, _prev, _last, acc),
    do: scan(rest, ctx, c, nil, [escape_char(c) | acc])

  # A byte that is not UTF-8 is not text Telegram accepts; it becomes the replacement character
  # rather than a refused message.
  defp plain(<<_byte, rest::binary>>, ctx, _prev, _last, acc),
    do: scan(rest, ctx, nil, nil, ["\uFFFD" | acc])

  # A delimited entity: the closing delimiter is the first one that leaves a content that is not
  # empty, does not start or end with a space, and passes `closes?` (the word-end rule for `_`).
  defp pair(rest, delim, kind, out, ctx, last, acc, closes? \\ fn _, _ -> true end) do
    case close(rest, delim, closes?) do
      {:ok, inner, after_close} ->
        cond do
          MapSet.member?(ctx, kind) ->
            scan(after_close, ctx, last_char(delim), nil, [inline(inner, ctx) | acc])

          last == kind ->
            # Two of a kind side by side: `_a__b_` reads as underline in MarkdownV2.
            scan(after_close, ctx, last_char(delim), nil, [inline(inner, ctx) | acc])

          true ->
            rendered = out <> inline(inner, MapSet.put(ctx, kind)) <> out
            scan(after_close, ctx, last_char(delim), kind, [rendered | acc])
        end

      :error ->
        scan(rest, ctx, last_char(delim), nil, [escape(delim) | acc])
    end
  end

  defp close(rest, delim, closes?) do
    rest
    |> :binary.matches(delim)
    |> Enum.find_value(:error, fn {at, len} ->
      inner = binary_part(rest, 0, at)
      after_close = binary_part(rest, at + len, byte_size(rest) - at - len)

      if inner != "" and not blank_edge?(inner) and not doubled?(delim, inner, after_close) and
           closes?.(inner, after_close),
         do: {:ok, inner, after_close}
    end)
  end

  # A one-character delimiter does not close on half of a doubled one: the `*` of `**` belongs
  # to a bold, not to the italic being closed.
  defp doubled?(<<d>>, inner, after_close),
    do: String.ends_with?(inner, <<d>>) or String.starts_with?(after_close, <<d>>)

  defp doubled?(_delim, _inner, _after_close), do: false

  defp blank_edge?(inner),
    do: String.match?(inner, ~r/\A\s/u) or String.match?(inner, ~r/\s\z/u)

  defp closes_at_word_end?(_inner, after_close) do
    case after_close do
      <<c::utf8, _::binary>> -> not word?(c)
      "" -> true
    end
  end

  defp link(text, ctx) do
    url_part = ~S"((?:[^\s()\\]|\([^\s()\\]*\))+)"

    case Regex.run(~r/\A\[([^\[\]\n]+)\]\(#{url_part}\)/u, text) do
      [whole, label, url] ->
        rest = binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole))

        if allowed_url?(url) and not MapSet.member?(ctx, :link) do
          rendered =
            "[" <> inline(label, MapSet.put(ctx, :link)) <> "](" <> escape_url(url) <> ")"

          {:ok, rendered, rest}
        else
          :error
        end

      nil ->
        :error
    end
  end

  defp allowed_url?(url) do
    case String.split(url, ":", parts: 2) do
      [scheme, rest] when rest != "" -> String.downcase(scheme) in @schemes
      _ -> false
    end
  end

  defp take_run(text, char), do: take_run(text, char, "")

  defp take_run(<<c, rest::binary>>, char, run) when c == char,
    do: take_run(rest, char, run <> <<c>>)

  defp take_run(rest, _char, run), do: {run, rest}

  defp last_char(delim), do: :binary.last(delim)

  ## Escaping

  defp escape_char(c) when c in @reserved, do: <<?\\, c>>
  defp escape_char(c), do: <<c::utf8>>

  defp escape_code(text), do: String.replace(text, ~r/[`\\]/, "\\\\\\0")
  defp escape_url(url), do: String.replace(url, ~r/[)\\]/, "\\\\\\0")

  defp word?(nil), do: false
  defp word?(c), do: String.match?(<<c::utf8>>, ~r/\A[\p{L}\p{N}]\z/u)
end
