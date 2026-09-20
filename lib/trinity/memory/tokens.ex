# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Tokens do
  @moduledoc """
  Token estimation and the context window. Slice 023.

  No tokenizer reaches this tree from the provider layer (NOTES.md), so the estimate is a
  shape: one token per three bytes, plus four per message for its framing, calibrated high
  against a live `usage.input_tokens` in the eval run (the measurement is in the slice's
  NOTES.md) so compaction comes early rather than late. The window is the registry entry's
  `context_tokens`; an entry without one is treated as `#{32_768}`, a floor.
  """

  alias Trinity.LLM.Request

  # Three, not the usual four: measured at slice 023 against openrouter:ling's own count on
  # the eval transcripts, the provider counted 1.3 to 2.1 times the four-byte estimate (the
  # structured call's schema is part of what it counts), so the estimate errs high, which
  # compacts earlier and never overflows late.
  @bytes_per_token 3
  @per_message 4
  @default_context 32_768
  @soft 0.7
  @hard 0.9

  @doc "An estimate for a text, a message map, a list of messages, or a whole request."
  @spec estimate(String.t() | map() | [map()] | Request.t()) :: non_neg_integer()
  def estimate(text) when is_binary(text),
    do: div(byte_size(text) + @bytes_per_token - 1, @bytes_per_token)

  def estimate(%Request{system: system, messages: messages, tools: tools}) do
    estimate(system || "") + estimate(messages) + estimate(Jason.encode!(tools))
  end

  def estimate(messages) when is_list(messages),
    do: Enum.reduce(messages, 0, &(estimate(&1) + &2))

  def estimate(%{content: content} = message) when is_map(message) do
    extra =
      case Map.get(message, :tool_calls, []) do
        [] -> 0
        calls -> calls |> Jason.encode!() |> estimate()
      end

    @per_message + estimate(to_string(content)) + extra
  end

  def estimate(%{} = other), do: @per_message + estimate(Jason.encode!(other))

  @doc "The context window of a model id (nil for the default), in tokens."
  @spec context_tokens(String.t() | nil) :: pos_integer()
  def context_tokens(model_id) do
    case Trinity.LLM.Registry.lookup(model_id) do
      {:ok, entry} -> Map.get(entry, :context_tokens, @default_context)
      _ -> @default_context
    end
  end

  @doc "The soft and hard thresholds of a window, in tokens (70 % and 90 %, `config :trinity, :compaction`)."
  @spec thresholds(pos_integer()) :: %{soft: pos_integer(), hard: pos_integer()}
  def thresholds(window) do
    cfg = Application.get_env(:trinity, :compaction, [])

    %{
      soft: trunc(window * Keyword.get(cfg, :soft, @soft)),
      hard: trunc(window * Keyword.get(cfg, :hard, @hard))
    }
  end

  @doc "The default window for an entry without one."
  @spec default_context() :: pos_integer()
  def default_context, do: @default_context
end
