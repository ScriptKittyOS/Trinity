# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Request do
  @moduledoc """
  What a caller asks a provider for. Slice 011.

  `messages` are maps with `role` and `content` (and `tool_call_id` for tool results, `tool_calls`
  for assistant turns that made them), in the shape the `messages` table stores; the adapter maps
  them to the provider's format. `tools` are maps with `name`, `description` and a JSON Schema
  under `parameters`. `params` carries `max_tokens`, `temperature` and provider hints such as
  `cache: true`. `model` is a registry id (`"provider:model"`); nil means the registry default.
  """

  @roles ~w(system user assistant tool)

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:tool_call_id) => String.t(),
          optional(:tool_calls) => [map()]
        }
  @type tool :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map()
        }
  @type t :: %__MODULE__{
          system: String.t() | nil,
          messages: [message()],
          tools: [tool()],
          model: String.t() | nil,
          params: map()
        }

  defstruct system: nil, messages: [], tools: [], model: nil, params: %{}

  @doc "Builds a request, refusing an unknown role or a tool without a name and parameters."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_request, term()}}
  def new(attrs) do
    attrs = Map.new(attrs)
    request = struct(__MODULE__, attrs)

    with :ok <- check_messages(request.messages),
         :ok <- check_tools(request.tools) do
      {:ok, request}
    end
  end

  @doc "Like `new/1` but raises on an invalid request."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid LLM request: #{inspect(reason)}"
    end
  end

  defp check_messages(messages) when is_list(messages) do
    Enum.reduce_while(messages, :ok, fn
      %{role: role, content: content}, :ok when role in @roles and is_binary(content) ->
        {:cont, :ok}

      other, :ok ->
        {:halt, {:error, {:invalid_request, {:message, other}}}}
    end)
  end

  defp check_messages(other), do: {:error, {:invalid_request, {:messages, other}}}

  defp check_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, :ok, fn
      %{name: name, parameters: %{} = _schema}, :ok when is_binary(name) -> {:cont, :ok}
      other, :ok -> {:halt, {:error, {:invalid_request, {:tool, other}}}}
    end)
  end

  defp check_tools(other), do: {:error, {:invalid_request, {:tools, other}}}
end
