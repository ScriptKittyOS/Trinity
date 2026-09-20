# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Providers.ReqLLM do
  @moduledoc """
  `Trinity.LLM.Provider` over req_llm (ADR-0003). Slice 011.

  A registry entry names the req_llm provider and model as `"<provider>:<model>"` in `:model`
  (the first colon splits them, so a model name may itself contain colons), the environment
  variable holding the key in `:api_key_env`, and, for OpenAI-compatible endpoints, the
  `:base_url`. Keys reach req_llm only as a per-request `:api_key` read through
  `Trinity.Config.secret/1`; a missing key is a permanent error before any request is made.

  Streaming: req_llm's chunks are `:content` (text), `:thinking` (dropped), `:tool_call` (a
  call opening, with `id` and `index` in its metadata, or a complete call with arguments) and
  `:meta` (argument fragments keyed by index, the finish reason, usage). This module assembles
  fragments per call and emits the seven `Trinity.LLM.Event` shapes and nothing else.
  """
  @behaviour Trinity.LLM.Provider

  alias Trinity.Config
  alias Trinity.LLM.{Error, Request}

  @impl true
  def stream(%Request{} = request, opts, emit) do
    with {:ok, spec, call_opts} <- prepare(request, opts) do
      case ReqLLM.stream_text(spec, context(request), call_opts) do
        {:ok, response} ->
          state = Enum.reduce(response.stream, new_state(), &handle_chunk(&1, &2, emit))
          usage = normalise_usage(ReqLLM.StreamResponse.usage(response))
          state |> close_open_calls(emit)
          emit.({:usage, usage})
          emit.({:done, state.finish || :stop})
          {:ok, usage}

        {:error, reason} ->
          {:error, classify(reason)}
      end
    end
  rescue
    e -> {:error, classify(e)}
  end

  @impl true
  def generate(%Request{} = request, opts) do
    with {:ok, spec, call_opts} <- prepare(request, opts),
         {:ok, response} <- wrap(ReqLLM.generate_text(spec, context(request), call_opts)) do
      {:ok,
       %{
         text: ReqLLM.Response.text(response) || "",
         tool_calls: Enum.map(ReqLLM.Response.tool_calls(response), &tool_call/1),
         usage: normalise_usage(ReqLLM.Response.usage(response)),
         finish: finish(ReqLLM.Response.finish_reason(response))
       }}
    end
  rescue
    e -> {:error, classify(e)}
  end

  @impl true
  def generate_object(%Request{} = request, schema, opts) do
    with {:ok, spec, call_opts} <- prepare(request, opts),
         {:ok, response} <-
           wrap(ReqLLM.generate_object(spec, context(request), schema, call_opts)) do
      {:ok, ReqLLM.Response.object(response), normalise_usage(ReqLLM.Response.usage(response))}
    end
  rescue
    e -> {:error, classify(e)}
  end

  @impl true
  def embed(texts, opts) do
    # The embedding call validates its own option set: no receive_timeout there, so the
    # budget travels as total_timeout instead.
    with {:ok, spec, call_opts} <- prepare(%Request{}, opts),
         embed_opts =
           call_opts
           |> Keyword.delete(:receive_timeout)
           |> Keyword.put(:total_timeout, receive_timeout())
           |> Keyword.put(:return_usage, true),
         {:ok, %{embedding: vectors, usage: usage}} <- wrap(ReqLLM.embed(spec, texts, embed_opts)) do
      vectors =
        if texts |> length() == 1 and is_list(hd(vectors)) == false, do: [vectors], else: vectors

      {:ok, vectors, normalise_usage(usage)}
    end
  rescue
    e -> {:error, classify(e)}
  end

  @impl true
  def models, do: []

  @impl true
  def capabilities(_model), do: [:stream, :tools, :json]

  ## Request mapping

  defp prepare(%Request{} = request, opts) do
    with {:ok, provider, model} <- split_model(Keyword.fetch!(opts, :model)),
         {:ok, key} <- Config.secret(Keyword.get(opts, :api_key_env, default_env(provider))) do
      call_opts =
        [api_key: key, receive_timeout: receive_timeout()]
        |> maybe_put(:base_url, Keyword.get(opts, :base_url))
        |> Keyword.merge(params(request, provider))
        |> maybe_put(:tools, tools(request))

      # An inline spec, not a catalog lookup: Trinity's registry is the catalog, and model ids
      # here are configured, so req_llm's "unverified model" warning does not apply. An
      # embedding model says so in its capabilities, or req_llm refuses the operation.
      spec = %{
        provider: provider,
        id: model,
        capabilities: capabilities_of(Keyword.get(opts, :caps, []))
      }

      {:ok, spec, call_opts}
    else
      {:error, {:missing_secret, var}} -> {:error, Error.permanent({:missing_secret, var})}
      {:error, reason} -> {:error, Error.permanent(reason)}
    end
  end

  defp capabilities_of(caps) do
    if :embed in caps, do: %{embeddings: true}, else: %{}
  end

  # The five providers SLICE.md names, and nothing else: a name from config never mints an
  # atom. `openai_compatible` is req_llm's openai provider with a base_url, which is how the
  # NVIDIA endpoint, Ollama and LM Studio are reached.
  @providers %{
    "anthropic" => :anthropic,
    "openai" => :openai,
    "openai_compatible" => :openai,
    "openrouter" => :openrouter,
    "google" => :google
  }

  defp split_model(spec) when is_binary(spec) do
    with [name, model] when model != "" <- String.split(spec, ":", parts: 2),
         {:ok, provider} <- Map.fetch(@providers, name) do
      {:ok, provider, model}
    else
      :error -> {:error, {:unknown_provider, spec}}
      _ -> {:error, {:bad_model_spec, spec}}
    end
  end

  defp default_env(provider),
    do: provider |> Atom.to_string() |> String.upcase() |> Kernel.<>("_API_KEY")

  # Reasoning models can sit for longer than req_llm's 30-second default before the first
  # byte; measured on the NVIDIA endpoint under load. Configurable, generous by default.
  defp receive_timeout do
    Keyword.get(Application.get_env(:trinity, :llm, []), :receive_timeout_ms, 120_000)
  end

  defp params(%Request{params: params}, provider) do
    params
    |> Enum.flat_map(fn
      {:max_tokens, n} ->
        [max_tokens: n]

      {:temperature, t} ->
        [temperature: t]

      {:cache, true} when provider == :anthropic ->
        [provider_options: [cache_control: %{type: "ephemeral"}]]

      {:cache, _} ->
        []

      {k, v} when k in [:top_p, :stop, :seed] ->
        [{k, v}]

      _ ->
        []
    end)
  end

  defp tools(%Request{tools: []}), do: nil

  defp tools(%Request{tools: tools}) do
    Enum.map(tools, fn tool ->
      ReqLLM.Tool.new!(
        name: tool.name,
        description: Map.get(tool, :description, ""),
        parameter_schema: tool.parameters,
        callback: fn _ -> {:ok, nil} end
      )
    end)
  end

  defp context(%Request{system: system, messages: messages}) do
    base = if system, do: [ReqLLM.Context.system(system)], else: []
    ReqLLM.Context.new(base ++ Enum.map(messages, &message/1))
  end

  defp message(%{role: "system", content: c}), do: ReqLLM.Context.system(c)
  defp message(%{role: "user", content: c}), do: ReqLLM.Context.user(c)

  defp message(%{role: "tool", content: c} = m),
    do: ReqLLM.Context.tool_result(Map.fetch!(m, :tool_call_id), c)

  defp message(%{role: "assistant", content: c} = m) do
    case Map.get(m, :tool_calls, []) do
      [] ->
        ReqLLM.Context.assistant(c)

      calls ->
        ReqLLM.Context.assistant(c, tool_calls: Enum.map(calls, &{&1.id, &1.name, &1.args}))
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  ## Stream assembly

  defp new_state, do: %{calls: %{}, order: [], finish: nil}

  defp handle_chunk(%{type: :content, text: text}, state, emit)
       when is_binary(text) and text != "" do
    emit.({:text_delta, text})
    state
  end

  defp handle_chunk(%{type: :tool_call, name: name, arguments: args, metadata: meta}, state, emit) do
    id = call_id(meta, state)

    state =
      if Map.has_key?(state.calls, id), do: state, else: open_call(state, id, name, meta, emit)

    if Map.get(meta, :expects_arg_fragments, false) or args == %{} do
      state
    else
      close_call(state, id, args, emit)
    end
  end

  defp handle_chunk(
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

  defp handle_chunk(%{type: :meta, metadata: meta}, state, emit) do
    state =
      case Map.get(meta, :finish_reason) do
        nil -> state
        reason -> %{state | finish: finish(reason)}
      end

    if state.finish in [:tool_calls, :stop, :length],
      do: close_open_calls(state, emit),
      else: state
  end

  defp handle_chunk(_other, state, _emit), do: state

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

  defp close_open_calls(state, emit) do
    Enum.reduce(state.order, state, fn id, acc ->
      case acc.calls[id] do
        %{open: true, fragments: fragments} ->
          close_call(acc, id, decode_fragments(fragments), emit)

        _ ->
          acc
      end
    end)
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

  defp tool_call(%{id: id, name: name, arguments: args}),
    do: %{id: id, name: name, args: args || %{}}

  defp tool_call(%{id: id, function: %{name: name, arguments: args}}),
    do: %{id: id, name: name, args: args || %{}}

  defp tool_call(other),
    do: %{id: Map.get(other, :id, ""), name: Map.get(other, :name, ""), args: %{}}

  defp finish(nil), do: :stop
  defp finish(reason) when is_atom(reason), do: reason
  defp finish("stop"), do: :stop
  defp finish("length"), do: :length
  defp finish("tool_calls"), do: :tool_calls
  defp finish("content_filter"), do: :content_filter
  # A reason the spec does not name is reported as :other, never minted into an atom.
  defp finish(other) when is_binary(other), do: :other

  defp normalise_usage(nil), do: %{}

  defp normalise_usage(usage) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, :input_tokens, 0) || 0,
      output_tokens: Map.get(usage, :output_tokens, 0) || 0,
      cached_tokens: Map.get(usage, :cached_tokens, 0) || 0,
      reasoning_tokens: Map.get(usage, :reasoning_tokens, 0) || 0,
      provider_cost: Map.get(usage, :total_cost)
    }
  end

  ## Errors

  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:error, reason}), do: {:error, classify(reason)}

  # req_llm wraps failures: a stream error carries its cause, an API error its status and a
  # retryable flag, and a class error a list of errors. The verdict is taken from the
  # innermost thing that has one. Found by the live suite: an upstream 429 arrived inside a
  # wrapper whose own status was nil and was called permanent.
  defp classify(%Error{} = e), do: e
  defp classify(%{status: status} = e) when is_integer(status), do: Error.from_status(status, e)
  defp classify(%{retryable: true} = e), do: Error.transient(e)
  defp classify(%Req.TransportError{} = e), do: Error.transient(e)
  defp classify(%Mint.TransportError{} = e), do: Error.transient(e)

  defp classify(%{__exception__: true} = e) do
    case inner(e) do
      nil -> if timeout?(e), do: Error.transient(e), else: Error.permanent(e)
      inner -> %{classify(inner) | reason: e}
    end
  end

  defp classify(other), do: Error.permanent(other)

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
