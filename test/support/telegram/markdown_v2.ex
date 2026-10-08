# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.FakeTelegram.MarkdownV2 do
  @moduledoc """
  Telegram's MarkdownV2 parse rules, as a checker the suite and the fake Bot API share (slice 071).

  Written from the Bot API's "MarkdownV2 style" section, and stricter than Telegram where the
  documentation is silent, so a text this accepts is one Telegram accepts and not the other way
  round:

  - outside an entity, each of `_ * [ ] ( ) ~ ` > # + - = | { } . !` is markup or must be escaped
    with `\\`, and `\\` itself must be escaped; `>` is markup only at the start of a line;
  - `\\` may escape any character with a code from 1 to 126, and nothing else;
  - inside `code` and `pre`, an unescaped `` ` `` ends the entity and `\\` must escape;
  - inside a link's `(...)`, an unescaped `)` ends it and `\\` must escape;
  - `__` is underline and is read before `_` (Telegram's greedy rule); `||` is a spoiler;
  - entities nest properly and none is left open at the end.

  `check/1` answers `:ok` or the first violation with its byte offset.
  """

  @reserved ~c"_*[]()~`>#+-=|{}.!"

  @doc "Whether Telegram would parse `text` as MarkdownV2, and the first reason it would not."
  @spec check(String.t()) :: :ok | {:error, {atom(), term(), non_neg_integer()}}
  def check(text) when is_binary(text), do: run(text, [], true, 0)

  defp run("", [], _line_start, _pos), do: :ok
  defp run("", stack, _line_start, pos), do: {:error, {:unclosed, stack, pos}}

  defp run(<<"\\", c::utf8, rest::binary>>, stack, _ls, pos) when c in 1..126,
    do: run(rest, stack, false, pos + 2)

  defp run(<<"\\", rest::binary>>, _stack, _ls, pos),
    do: {:error, {:bad_escape, String.slice(rest, 0, 1), pos}}

  defp run(<<"```", rest::binary>>, stack, _ls, pos) do
    case verbatim(skip_language(rest), "```", pos + 3) do
      {:ok, rest, pos} -> run(rest, stack, false, pos)
      error -> error
    end
  end

  defp run(<<"`", rest::binary>>, stack, _ls, pos) do
    case verbatim(rest, "`", pos + 1) do
      {:ok, rest, pos} -> run(rest, stack, false, pos)
      error -> error
    end
  end

  defp run(<<">", rest::binary>>, stack, true, pos), do: run(rest, stack, false, pos + 1)
  defp run(<<"||", rest::binary>>, stack, _ls, pos), do: toggle(:spoiler, rest, stack, pos, 2)
  defp run(<<"__", rest::binary>>, stack, _ls, pos), do: toggle(:underline, rest, stack, pos, 2)
  defp run(<<"_", rest::binary>>, stack, _ls, pos), do: toggle(:italic, rest, stack, pos, 1)
  defp run(<<"*", rest::binary>>, stack, _ls, pos), do: toggle(:bold, rest, stack, pos, 1)
  defp run(<<"~", rest::binary>>, stack, _ls, pos), do: toggle(:strike, rest, stack, pos, 1)
  defp run(<<"[", rest::binary>>, stack, _ls, pos), do: run(rest, [:link | stack], false, pos + 1)

  defp run(<<"](", rest::binary>>, [:link | stack], _ls, pos) do
    case url(rest, pos + 2) do
      {:ok, rest, pos} -> run(rest, stack, false, pos)
      error -> error
    end
  end

  defp run(<<"\n", rest::binary>>, stack, _ls, pos), do: run(rest, stack, true, pos + 1)

  defp run(<<c, _::binary>>, _stack, _ls, pos) when c in @reserved,
    do: {:error, {:unescaped, <<c>>, pos}}

  defp run(<<c::utf8, rest::binary>>, stack, _ls, pos),
    do: run(rest, stack, false, pos + byte_size(<<c::utf8>>))

  defp run(<<byte, _::binary>>, _stack, _ls, pos), do: {:error, {:not_utf8, byte, pos}}

  defp toggle(kind, rest, [kind | stack], pos, len), do: run(rest, stack, false, pos + len)

  defp toggle(kind, rest, stack, pos, len) do
    if kind in stack,
      do: {:error, {:improper_nesting, kind, pos}},
      else: run(rest, [kind | stack], false, pos + len)
  end

  # A pre block's language runs to the first newline; it may be absent.
  defp skip_language(rest) do
    case String.split(rest, "\n", parts: 2) do
      [lang, body] -> if Regex.match?(~r/\A[^`\s\\]*\z/, lang), do: body, else: rest
      [_] -> rest
    end
  end

  # Inside code or pre: `\\` escapes, the closing delimiter ends it, everything else is text.
  defp verbatim(<<"\\", c::utf8, rest::binary>>, close, pos) when c in 1..126,
    do: verbatim(rest, close, pos + 2)

  defp verbatim(<<"\\", _::binary>>, _close, pos), do: {:error, {:bad_escape_in_code, nil, pos}}

  defp verbatim(text, close, pos) do
    cond do
      text == "" ->
        {:error, {:unclosed, [:code], pos}}

      String.starts_with?(text, close) ->
        {:ok, binary_part(text, byte_size(close), byte_size(text) - byte_size(close)),
         pos + byte_size(close)}

      String.starts_with?(text, "`") ->
        {:error, {:unescaped_in_code, "`", pos}}

      true ->
        <<c::utf8, rest::binary>> = text
        verbatim(rest, close, pos + byte_size(<<c::utf8>>))
    end
  end

  defp url(<<"\\", c::utf8, rest::binary>>, pos) when c in 1..126, do: url(rest, pos + 2)
  defp url(<<"\\", _::binary>>, pos), do: {:error, {:bad_escape_in_url, nil, pos}}
  defp url(<<")", rest::binary>>, pos), do: {:ok, rest, pos + 1}
  defp url("", pos), do: {:error, {:unclosed, [:url], pos}}
  defp url(<<c::utf8, rest::binary>>, pos), do: url(rest, pos + byte_size(<<c::utf8>>))
end
