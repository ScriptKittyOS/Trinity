# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Registry do
  @moduledoc """
  The models Trinity may use, from `config :trinity, :llm`. Slice 011.

      config :trinity, :llm,
        default_model: "openrouter:ling",
        providers: %{req_llm: Trinity.LLM.Providers.ReqLLM},
        models: [
          %{id: "openrouter:ling", provider: :req_llm, model: "openrouter:inclusionai/ling-3.0-flash-vl:free",
            caps: [:stream, :tools, :json], price: %{input: 0.0, output: 0.0}}
        ]

  `price` is US dollars per million tokens, input and output, and is the source of every cost
  Trinity records; a provider's own figure is kept beside it for comparison and never used.
  Read at call time, not cached, so a test or a settings page can change the default without a
  restart (AC7).
  """

  @type entry :: %{
          required(:id) => String.t(),
          required(:provider) => atom(),
          required(:model) => String.t(),
          required(:caps) => [atom() | {atom(), term()}],
          required(:price) => %{input: number(), output: number()},
          optional(:base_url) => String.t(),
          optional(:api_key_env) => String.t()
        }

  @doc "Every registry entry."
  @spec models() :: [entry()]
  def models, do: Keyword.get(config(), :models, [])

  @doc "The default model id, or nil when the registry is empty."
  @spec default_model() :: String.t() | nil
  def default_model, do: Keyword.get(config(), :default_model)

  @doc "The entry for an id, or the default's when nil, refusing an unknown id by name."
  @spec lookup(String.t() | nil) :: {:ok, entry()} | {:error, {:unknown_model, String.t() | nil}}
  def lookup(nil), do: lookup(default_model())

  def lookup(id) do
    case Enum.find(models(), &(&1.id == id)) do
      nil -> {:error, {:unknown_model, id}}
      entry -> {:ok, entry}
    end
  end

  @doc "The module implementing `Trinity.LLM.Provider` for an entry's provider atom."
  @spec provider_module(entry()) :: {:ok, module()} | {:error, {:unknown_provider, atom()}}
  def provider_module(%{provider: provider}) do
    case Map.fetch(Keyword.get(config(), :providers, %{}), provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  defp config, do: Application.get_env(:trinity, :llm, [])
end
