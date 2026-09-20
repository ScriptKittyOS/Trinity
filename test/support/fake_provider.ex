# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Providers.Fake do
  @moduledoc """
  A scripted provider for tests. Slice 011. The default script streams two text deltas, one
  tool call in three chunks, usage and done. A test overrides the script through the process
  dictionary of the calling process (`script/1`), or asks for `n` failures before success
  (`fail/2`), so the retry policy is exercised without a network.
  """
  @behaviour Trinity.LLM.Provider

  alias Trinity.LLM.Error

  @default_script [
    {:text_delta, "Hello, "},
    {:text_delta, "world."},
    {:tool_call_start, "call_1", "get_weather"},
    {:tool_call_delta, "call_1", ~s({"city":)},
    {:tool_call_delta, "call_1", ~s("Paris"})},
    {:tool_call_end, "call_1", %{"city" => "Paris"}},
    {:usage, %{input_tokens: 10, output_tokens: 5}},
    {:done, :tool_calls}
  ]

  @doc "Sets the events the next stream emits, for the calling process."
  @spec script([Trinity.LLM.Event.t()]) :: :ok
  def script(events) do
    Process.put({__MODULE__, :script}, events)
    :ok
  end

  @doc "Makes the next `n` calls fail with `error` before succeeding."
  @spec fail(non_neg_integer(), Error.t()) :: :ok
  def fail(n, %Error{} = error) do
    Process.put({__MODULE__, :fail}, {n, error})
    :ok
  end

  @doc "How many calls the provider has served in this process."
  @spec calls() :: non_neg_integer()
  def calls, do: Process.get({__MODULE__, :calls}, 0)

  @impl true
  def stream(_request, _opts, emit) do
    with :ok <- maybe_fail() do
      events = Process.get({__MODULE__, :script}, @default_script)
      Enum.each(events, emit)
      {:ok, usage_of(events)}
    end
  end

  @impl true
  def generate(_request, _opts) do
    with :ok <- maybe_fail() do
      {:ok,
       %{
         text: "Hello, world.",
         tool_calls: [%{id: "call_1", name: "get_weather", args: %{"city" => "Paris"}}],
         usage: %{input_tokens: 10, output_tokens: 5},
         finish: :tool_calls
       }}
    end
  end

  @impl true
  def generate_object(_request, schema, _opts) do
    with :ok <- maybe_fail() do
      object =
        schema
        |> Map.get("properties", %{})
        |> Map.new(fn
          {k, %{"type" => "integer"}} -> {k, 42}
          {k, %{"type" => "number"}} -> {k, 4.2}
          {k, %{"type" => "boolean"}} -> {k, true}
          {k, _} -> {k, "fake"}
        end)

      {:ok, object, %{input_tokens: 8, output_tokens: 4}}
    end
  end

  @impl true
  def embed(texts, opts) do
    with :ok <- maybe_fail() do
      dim = Keyword.get(opts, :dim, 8)
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.5, dim) end), %{input_tokens: length(texts)}}
    end
  end

  @impl true
  def models, do: ["chat", "embed"]

  @impl true
  def capabilities("embed"), do: [:embed, {:embed_dim, 8}]
  def capabilities(_), do: [:stream, :tools, :json]

  defp maybe_fail do
    Process.put({__MODULE__, :calls}, calls() + 1)

    case Process.get({__MODULE__, :fail}) do
      {n, error} when n > 0 ->
        Process.put({__MODULE__, :fail}, {n - 1, error})
        {:error, error}

      _ ->
        :ok
    end
  end

  defp usage_of(events) do
    Enum.find_value(events, %{}, fn
      {:usage, usage} -> usage
      _ -> nil
    end)
  end
end
