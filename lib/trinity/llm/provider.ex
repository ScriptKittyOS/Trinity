# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Provider do
  @moduledoc """
  The behaviour every provider implements and the only thing `Trinity.LLM` calls. Slice 011.

  `opts` carries what the registry entry says about the model (`:model`, the provider's own
  model name; `:base_url` and `:api_key` for OpenAI-compatible endpoints; `:price`) plus what
  the caller passed. A provider emits `Trinity.LLM.Event` shapes through `emit` in the calling
  process and returns when the stream ends. Errors are `Trinity.LLM.Error` structs.
  """

  alias Trinity.LLM.{Error, Request}

  @type opts :: keyword()
  @type emit :: (Trinity.LLM.Event.t() -> any())
  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:cached_tokens) => non_neg_integer(),
          optional(:reasoning_tokens) => non_neg_integer(),
          optional(:provider_cost) => number() | nil
        }
  @type result :: %{
          text: String.t(),
          tool_calls: [%{id: String.t(), name: String.t(), args: map()}],
          usage: usage(),
          finish: atom()
        }

  @doc "Streams events through `emit`; returns the usage when the stream ends."
  @callback stream(Request.t(), opts(), emit()) :: {:ok, usage()} | {:error, Error.t()}

  @doc "One complete response."
  @callback generate(Request.t(), opts()) :: {:ok, result()} | {:error, Error.t()}

  @doc "A map validated against `schema` (a JSON Schema), with the usage beside it."
  @callback generate_object(Request.t(), schema :: map(), opts()) ::
              {:ok, map(), usage()} | {:error, Error.t()}

  @doc "One vector per text, of the dimension `capabilities/1` declares."
  @callback embed([String.t()], opts()) :: {:ok, [[float()]], usage()} | {:error, Error.t()}

  @doc "The provider's own model names it can serve, for diagnostics."
  @callback models() :: [String.t()]

  @doc "Capabilities of a model: `:stream`, `:tools`, `:json`, `:embed`, `{:embed_dim, n}`."
  @callback capabilities(model :: String.t()) :: [atom() | {atom(), term()}]
end
