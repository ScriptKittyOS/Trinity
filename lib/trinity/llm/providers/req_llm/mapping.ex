# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Providers.ReqLLM.Mapping do
  @moduledoc """
  The pure half of the req_llm adapter: streamed chunks into `Trinity.LLM.Event` shapes, a
  provider response into a result, req_llm errors into `Trinity.LLM.Error`. No network, so
  the default test suite covers it with recorded chunk sequences; the live suite covers the
  half that talks.

  Streaming, as req_llm 1.24.0 emits it: `:content` is a text delta; `:thinking` is dropped;
  a `:tool_call` chunk opens a call (its metadata carries `id`, `index` and, when arguments
  follow in fragments, `expects_arg_fragments`), or opens and closes one when it arrives with
  complete arguments; a `:meta` chunk carries `tool_call_args` fragments keyed by index, or the
  `finish_reason` that closes every open call.
  """

  alias Trinity.LLM.Error

  @type emit :: (Trinity.LLM.Event.t() -> any())
  @type state :: %{calls: map(), order: [String.t()], finish: atom() | nil}

  @doc "The empty assembly state."
  @spec new_state() :: state()
  def new_state, do: %{calls: %{}, order: [], finish: nil}

  @doc "Folds every chunk of a stream through `handle_chunk/3`, then closes any call still open."
  @spec reduce(Enumerable.t(), emit()) :: state()
  def reduce(chunks, emit) do
    chunks
    |> Enum.reduce(new_state(), &handle_chunk(&1, &2, emit))
    |> close_open_calls(emit)
  end

  @doc "One chunk into zero or more events, returning the new state."
  @spec handle_chunk(map(), state(), emit()) :: state()
  def handle_chunk(%{type: :content, text: text}, state, emit)
      when is_binary(text) and text != "" do
    emit.({:text_delta, text})
    state
  end

  def handle_chunk(%{type: :tool_call, name: name, arguments: args, metadata: meta}, state, emit) do
    id = call_id(meta, state)

    state =
      if Map.has_key?(state.calls, id), do: state, else: open_call(state, id, name, meta, emit)

    if Map.get(meta, :expects_arg_fragments, false) or args == %{} do
      state
    else
      close_call(state, id, args, emit)
    end
  end

  def handle_chunk(
        %{type: :meta, metadata: %{tool_call_args: %{index: index, fragment: fragment}}},
        state,
        emit
      ) do
    case Enum.find(state.calls, fn {_id, call} -> call.index == index and call.open end) do
      {id, call} ->
        emit.({:tool_call_delta, id, fragment})
        put_in(state.calls[id], %{call | fragments: [fragment | call.fragments]})

      nil ->
        state
    end
  end

  def handle_chunk(%{type: :meta, metadata: meta}, state, emit) do
    state =
      case Map.get(meta, :finish_reason) do
        nil -> state
        reason -> %{state | finish: finish(reason)}
      end

    if state.finish in [:tool_calls, :stop, :length],
      do: close_open_calls(state, emit),
      else: state
  end

  def handle_chunk(_other, state, _emit), do: state

  @doc "Closes every call still open, decoding its fragments; called at the end of a stream."
  @spec close_open_calls(state(), emit()) :: state()
  def close_open_calls(state, emit) do
    Enum.reduce(state.order, state, fn id, acc ->
      case acc.calls[id] do
        %{open: true, fragments: fragments} ->
          close_call(acc, id, decode_fragments(fragments), emit)

        _ ->
          acc
      end
    end)
  end

  defp call_id(meta, state) do
    case Map.get(meta, :id) do
      id when is_binary(id) -> id
      _ -> "call_#{map_size(state.calls) + 1}"
    end
  end

  defp open_call(state, id, name, meta, emit) do
    emit.({:tool_call_start, id, name})
    call = %{name: name, index: Map.get(meta, :index), fragments: [], open: true}
    %{state | calls: Map.put(state.calls, id, call), order: state.order ++ [id]}
  end

  defp close_call(state, id, args, emit) do
    emit.({:tool_call_end, id, args})
    put_in(state.calls[id].open, false)
  end

  # Fragments arrive in order and are kept reversed; an unparseable body is an empty map,
  # which the consumer sees as a tool called with no arguments rather than a crash mid-stream.
  defp decode_fragments(fragments) do
    case Jason.decode(fragments |> Enum.reverse() |> IO.iodata_to_binary()) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  ## Results

  @doc "A tool call from a complete response, in Trinity's shape."
  @spec tool_call(map()) :: %{id: String.t(), name: String.t(), args: map()}
  def tool_call(%{id: id, name: name, arguments: args}),
    do: %{id: id, name: name, args: args || %{}}

  def tool_call(%{id: id, function: %{name: name, arguments: args}}),
    do: %{id: id, name: name, args: args || %{}}

  def tool_call(other),
    do: %{id: Map.get(other, :id, ""), name: Map.get(other, :name, ""), args: %{}}

  @doc "A finish reason from the closed vocabulary; anything else is `:other`, never a new atom."
  @spec finish(term()) :: atom()
  def finish(nil), do: :stop
  def finish(reason) when is_atom(reason), do: reason
  def finish("stop"), do: :stop
  def finish("length"), do: :length
  def finish("tool_calls"), do: :tool_calls
  def finish("content_filter"), do: :content_filter
  def finish(other) when is_binary(other), do: :other

  @doc "Usage in Trinity's keys; the provider's own cost figure kept aside as `provider_cost`."
  @spec normalise_usage(map() | nil) :: map()
  def normalise_usage(nil), do: %{}

  def normalise_usage(usage) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, :input_tokens, 0) || 0,
      output_tokens: Map.get(usage, :output_tokens, 0) || 0,
      cached_tokens: Map.get(usage, :cached_tokens, 0) || 0,
      reasoning_tokens: Map.get(usage, :reasoning_tokens, 0) || 0,
      provider_cost: Map.get(usage, :total_cost)
    }
  end

  ## Errors

  @doc "Passes an ok through and classifies an error."
  @spec wrap({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, Error.t()}
  def wrap({:ok, _} = ok), do: ok
  def wrap({:error, reason}), do: {:error, classify(reason)}

  @doc """
  A failure as a `Trinity.LLM.Error`. req_llm wraps failures: a stream error carries its
  cause, an API error its status and a retryable flag, a class error a list of errors. The
  verdict comes from the innermost thing that has one. Found by the live suite: an upstream
  429 arrived inside a wrapper whose own status was nil and was called permanent.
  """
  @spec classify(term()) :: Error.t()
  def classify(%Error{} = e), do: e
  def classify(%{status: status} = e) when is_integer(status), do: Error.from_status(status, e)
  def classify(%{retryable: true} = e), do: Error.transient(e)
  def classify(%Req.TransportError{} = e), do: Error.transient(e)
  def classify(%Mint.TransportError{} = e), do: Error.transient(e)

  def classify(%{__exception__: true} = e) do
    case inner(e) do
      nil -> if timeout?(e), do: Error.transient(e), else: Error.permanent(e)
      inner -> %{classify(inner) | reason: e}
    end
  end

  def classify(other), do: Error.permanent(other)

  defp inner(%{cause: %{__exception__: true} = c}), do: c
  defp inner(%{errors: [%{__exception__: true} = c | _]}), do: c
  defp inner(%{reason: %{__exception__: true} = c}), do: c
  defp inner(_), do: nil

  defp timeout?(%{cause: :timeout}), do: true
  defp timeout?(%{reason: reason}) when reason in [:timeout, :econnrefused, :closed], do: true

  defp timeout?(%{reason: reason}) when is_binary(reason),
    do: reason =~ ~r/timeout|closed|refused/i

  defp timeout?(_), do: false
end
