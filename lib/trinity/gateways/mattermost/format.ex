# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Format do
  @moduledoc """
  Trinity's text as Mattermost posts (slice 072).

  **Chunks fit the server's limit as the server counts it.** Mattermost renders markdown, so the
  shared `Trinity.Gateways.Format` does the splitting; but the server measures a post in code
  points (runes) and the shared chunker in graphemes, and a grapheme can be several code points
  (a flag is two, a family emoji seven). The shared chunker also closes and re-opens a code fence
  around a split, which adds eight characters after the split was measured. So it is asked for
  chunks eight shorter than the limit, and any chunk still over the limit in code points is cut
  again at grapheme boundaries. Every post this module produces is within `max_length` code points;
  `test/trinity/gateways/mattermost/format_test.exs` holds that as a property.

  **Approvals** are rendered as the shared text with the slash command a Mattermost user can
  actually type (`/trinity approve …`: a bare `/approve` is looked up by the server as a command of
  its own and never reaches the bot), and, when the router says the channel may answer and the
  server can reach Trinity, a message attachment carrying one button that opens the dialog.
  """

  alias Trinity.Gateways.Adapter
  alias Trinity.Gateways.Format, as: Shared
  alias Trinity.Gateways.Mattermost.Signing
  alias Trinity.Permissions.Approval

  # "```\n" before a re-opened chunk and "\n```" after one left open.
  @fence_overhead 8

  @doc "An assistant message as posts, each within the server's limit in code points."
  @spec format(String.t(), Adapter.capabilities()) :: [String.t()]
  def format(text, %{max_length: max} = capabilities) when is_binary(text) do
    # The fence allowance is only taken when there is a fence to re-open.
    budget = if String.contains?(text, "```"), do: max(max - @fence_overhead, 1), else: max

    text
    |> Shared.format(%{capabilities | max_length: budget})
    |> Enum.flat_map(&fit(&1, max))
  end

  @doc """
  Cuts a chunk that is over `max` code points at grapheme boundaries, and a single grapheme
  longer than `max` at code points: the last resort, which no ordinary text reaches.
  """
  @spec fit(String.t(), pos_integer()) :: [String.t()]
  def fit(chunk, max) do
    if codepoints(chunk) <= max do
      [chunk]
    else
      chunk
      |> String.graphemes()
      |> Enum.flat_map(&pieces(&1, max))
      |> Enum.chunk_while({[], 0}, &pack(&1, &2, max), &flush/1)
    end
  end

  # A grapheme is a piece unless it alone is over the limit, when its code points are.
  defp pieces(grapheme, max) do
    if codepoints(grapheme) > max, do: String.codepoints(grapheme), else: [grapheme]
  end

  defp pack(piece, {acc, n}, max) do
    size = codepoints(piece)

    if n + size > max,
      do: {:cont, join(acc), {[piece], size}},
      else: {:cont, {[piece | acc], n + size}}
  end

  defp flush({[], _n}), do: {:cont, {[], 0}}
  defp flush({acc, _n}), do: {:cont, join(acc), {[], 0}}

  defp join(reversed), do: reversed |> Enum.reverse() |> Enum.join()

  @doc "How the server measures a post: in code points."
  @spec codepoints(String.t()) :: non_neg_integer()
  def codepoints(text), do: text |> String.codepoints() |> length()

  @doc "An approval as a post's text. Mattermost's command form, not the router's bare one."
  @spec render_approval(Approval.t(), Adapter.capabilities()) :: Adapter.outbound()
  def render_approval(%Approval{} = approval, capabilities) do
    {:message, text} = Shared.render_approval(approval, capabilities)
    short = Shared.short(approval.id)

    text =
      String.replace(
        text,
        "Answer with /approve #{short} or /deny #{short}",
        "Answer with /trinity approve #{short} or /trinity deny #{short}"
      )

    {:message, text |> format(capabilities) |> List.first()}
  end

  @doc """
  The props of a post with buttons (slice 071's `{:message, text, buttons}`), when the server can
  call back: one attachment with one button, "Answer", which opens a dialog offering the buttons'
  labels. The button's context is signed (`Signing`) over the answers and the conversation; the
  server keeps an action's context to itself and sends it back only with the press.
  """
  @spec button_props([{String.t(), String.t()}], map(), String.t(), String.t()) :: map()
  def button_props(buttons, where, text, callback_url) do
    conversation =
      Trinity.Gateways.Mattermost.Conversation.of(where.channel_id, where.root_id)

    context = %{"token" => Signing.button(buttons, conversation, summary(text))}

    %{
      "attachments" => [
        %{
          "fallback" => "Answer",
          "actions" => [
            %{
              "id" => "answer",
              "name" => "Answer",
              "type" => "button",
              "style" => "primary",
              "integration" => %{
                "url" => callback_url <> "/gateways/callback/mattermost/action",
                "context" => context
              }
            }
          ]
        }
      ]
    }
  end

  # The dialog repeats what is being decided; the first line is "Approval needed: tool (risk)".
  defp summary(text), do: text |> String.split("\n", parts: 3) |> Enum.take(2) |> Enum.join("\n")
end
