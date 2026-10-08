# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Request do
  @moduledoc """
  What a caller asks a provider for. Slice 011.

  `messages` are maps with `role` and `content` (and `tool_call_id` for tool results, `tool_calls`
  for assistant turns that made them, `images` for a user message that came with images, slice 071),
  in the shape the `messages` table stores; the adapter maps them to the provider's format. `tools` are maps with `name`, `description` and a JSON Schema
  under `parameters`. `params` carries `max_tokens`, `temperature` and provider hints such as
  `cache: true`. `model` is a registry id (`"provider:model"`); nil means the registry default.
  """

  @roles ~w(system user assistant tool)

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:tool_call_id) => String.t(),
          optional(:tool_calls) => [map()],
          optional(:images) => [image()]
        }
  @typedoc "An image a user message carries: a file on this machine and its media type (slice 071)."
  @type image :: %{required(:path) => String.t(), required(:media_type) => String.t()}
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

  @doc """
  The request a model with or without vision can take (slice 071). With `vision?` it is unchanged.
  Without it, every message's images are removed and replaced by a sentence in its text saying an
  image was attached and this model cannot see it, so the turn runs and the model can say so rather
  than answer as if nothing had been sent. The decision is the registry's (`caps: [:vision]`), never
  the caller's.
  """
  @spec fit_images(t(), boolean()) :: t()
  def fit_images(%__MODULE__{} = request, true), do: request

  def fit_images(%__MODULE__{messages: messages} = request, false) do
    %{request | messages: Enum.map(messages, &without_images/1)}
  end

  defp without_images(%{images: [_ | _] = images} = message) do
    note =
      "[#{length(images)} image(s) attached; the model in use does not accept images, " <>
        "so they were not sent to it]"

    message |> Map.delete(:images) |> Map.update!(:content, &(&1 <> "\n\n" <> note))
  end

  defp without_images(message), do: Map.delete(message, :images)

  defp check_messages(messages) when is_list(messages) do
    Enum.reduce_while(messages, :ok, fn
      %{role: role, content: content} = message, :ok when role in @roles and is_binary(content) ->
        if images_ok?(message),
          do: {:cont, :ok},
          else: {:halt, {:error, {:invalid_request, {:images, message}}}}

      other, :ok ->
        {:halt, {:error, {:invalid_request, {:message, other}}}}
    end)
  end

  defp check_messages(other), do: {:error, {:invalid_request, {:messages, other}}}

  # Images belong to a user message and are a list of paths with media types; anything else is a
  # malformed request and refused by name rather than half-sent.
  defp images_ok?(%{images: images, role: "user"}) when is_list(images),
    do:
      Enum.all?(images, &match?(%{path: p, media_type: t} when is_binary(p) and is_binary(t), &1))

  defp images_ok?(%{images: _}), do: false
  defp images_ok?(_message), do: true

  defp check_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, :ok, fn
      %{name: name, parameters: %{} = _schema}, :ok when is_binary(name) -> {:cont, :ok}
      other, :ok -> {:halt, {:error, {:invalid_request, {:tool, other}}}}
    end)
  end

  defp check_tools(other), do: {:error, {:invalid_request, {:tools, other}}}
end
