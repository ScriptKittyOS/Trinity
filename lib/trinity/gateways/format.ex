# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Format do
  @moduledoc """
  Turning what Trinity says into what a channel can carry (slice 070): the default
  `format/2` and `render_approval/2` every adapter delegates to unless its platform needs its own
  dialect.

  Two jobs. **Chunking**: a platform refuses a message past its limit, so a long answer is split
  at the latest paragraph, then line, then word boundary that fits, and only cut mid-word when a
  single word is longer than the limit. A fenced code block that has to be split is re-opened on
  the next chunk with its own fence, because half a fence renders the rest of the message as code.
  **Plain text**: a channel without markdown gets the emphasis and heading markers removed rather
  than shown; fences become plain lines. That is a reduction and it is named as one: it is not a
  markdown renderer, and nothing here tries to be.
  """

  alias Trinity.Gateways.Adapter
  alias Trinity.Permissions.Approval

  @fence "```"

  @doc "An assistant message as the channel's text, split to its length limit."
  @spec format(String.t(), Adapter.capabilities()) :: [String.t()]
  def format(text, capabilities) when is_binary(text) do
    text
    |> then(fn t -> if capabilities.markdown, do: t, else: plain(t) end)
    |> chunk(capabilities.max_length)
  end

  @doc """
  Splits text into pieces of at most `max` graphemes, at the latest boundary that fits. An open
  code fence is closed at the end of a chunk and re-opened at the start of the next.
  """
  @spec chunk(String.t(), pos_integer()) :: [String.t()]
  def chunk(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    text
    |> do_chunk(max, [])
    |> Enum.reverse()
    |> reopen_fences()
  end

  defp do_chunk(text, max, acc) do
    if String.length(text) <= max do
      [text | acc]
    else
      {head, rest} = split_at_boundary(text, max)
      do_chunk(String.trim_leading(rest), max, [head | acc])
    end
  end

  # The latest paragraph, line or word boundary inside the limit; a hard cut when a single word
  # is longer than the limit (a URL, a base64 blob) and there is no boundary to prefer.
  defp split_at_boundary(text, max) do
    head = String.slice(text, 0, max)

    case boundary(head) do
      nil -> {head, String.slice(text, max..-1//1)}
      at -> {String.trim_trailing(String.slice(head, 0, at)), String.slice(text, at..-1//1)}
    end
  end

  defp boundary(head) do
    Enum.find_value([~r/\n\n(?!.*\n\n)/s, ~r/\n(?!.*\n)/s, ~r/ (?!.* )/s], fn re ->
      case Regex.run(re, head, return: :index) do
        [{start, len}] -> start + len
        _ -> nil
      end
    end)
  end

  # A chunk holding an odd number of fences left one open: close it, and open the next chunk with
  # a fence of its own so the block keeps rendering as code.
  defp reopen_fences(chunks) do
    {out, _open} =
      Enum.map_reduce(chunks, false, fn chunk, open? ->
        chunk = if open?, do: @fence <> "\n" <> chunk, else: chunk
        now_open? = chunk |> String.split(@fence) |> length() |> rem(2) == 0
        {if(now_open?, do: chunk <> "\n" <> @fence, else: chunk), now_open?}
      end)

    out
  end

  @doc "Markdown reduced to text for a channel that renders none of it."
  @spec plain(String.t()) :: String.t()
  def plain(text) when is_binary(text) do
    text
    |> String.replace(~r/^#{@fence}.*$/m, "")
    |> String.replace(~r/^#+\s*/m, "")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/(?<![*\w])\*([^*\n]+)\*(?!\*)/, "\\1")
    |> String.replace(~r/(?<![`\w])`([^`\n]+)`(?!`)/, "\\1")
    # `[ \t]` and not `\s`: `\s` matches a newline, so the blank line before a list would be
    # eaten and two paragraphs would become one (found by the test below).
    |> String.replace(~r/^[ \t]*[-*][ \t]+/m, "• ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  @doc """
  An approval request as a message the conversation can answer. The commands are written out
  whether or not the channel has buttons: a channel without them still has to be able to answer,
  and `Trinity.Gateways.Commands` accepts the text form everywhere.
  """
  @spec render_approval(Approval.t(), Adapter.capabilities()) :: Adapter.outbound()
  def render_approval(%Approval{} = approval, capabilities) do
    body = """
    Approval needed: #{approval.tool} (#{approval.risk})
    #{summarise(approval.args)}
    Answer with /approve #{short(approval.id)} or /deny #{short(approval.id)}
    """

    {:message, body |> String.trim() |> chunk(capabilities.max_length) |> List.first()}
  end

  @doc "The short form of an approval id a person can type back."
  @spec short(String.t()) :: String.t()
  def short(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp summarise(args) when map_size(args) == 0, do: "(no arguments)"

  defp summarise(args) do
    args
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{truncate(v)}" end)
  end

  defp truncate(value) do
    value |> to_string() |> String.slice(0, 40)
  end
end
