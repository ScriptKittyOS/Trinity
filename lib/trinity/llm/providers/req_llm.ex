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

  The half that talks lives here; the pure half (chunks into events, responses into results,
  errors into `Trinity.LLM.Error`) is `Trinity.LLM.Providers.ReqLLM.Mapping`, tested without a
  network.
  """
  @behaviour Trinity.LLM.Provider

  alias Trinity.Config
  alias Trinity.LLM.{Error, Request}
  alias Trinity.LLM.Providers.ReqLLM.Mapping

  @impl true
  def stream(%Request{} = request, opts, emit) do
    with {:ok, spec, call_opts} <- prepare(request, opts) do
      case ReqLLM.stream_text(spec, context(request), call_opts) do
        {:ok, response} ->
          state = Mapping.reduce(response.stream, emit)
          usage = Mapping.normalise_usage(ReqLLM.StreamResponse.usage(response))
          emit.({:usage, usage})
          emit.({:done, state.finish || :stop})
          {:ok, usage}

        {:error, reason} ->
          {:error, Mapping.classify(reason)}
      end
    end
  rescue
    e -> {:error, Mapping.classify(e)}
  end

  @impl true
  def generate(%Request{} = request, opts) do
    with {:ok, spec, call_opts} <- prepare(request, opts),
         {:ok, response} <- Mapping.wrap(ReqLLM.generate_text(spec, context(request), call_opts)) do
      {:ok,
       %{
         text: ReqLLM.Response.text(response) || "",
         tool_calls: Enum.map(ReqLLM.Response.tool_calls(response), &Mapping.tool_call/1),
         usage: Mapping.normalise_usage(ReqLLM.Response.usage(response)),
         finish: Mapping.finish(ReqLLM.Response.finish_reason(response))
       }}
    end
  rescue
    e -> {:error, Mapping.classify(e)}
  end

  @impl true
  def generate_object(%Request{} = request, schema, opts) do
    with {:ok, spec, call_opts} <- prepare(request, opts),
         {:ok, response} <-
           Mapping.wrap(ReqLLM.generate_object(spec, context(request), schema, call_opts)) do
      # Slice 023: a response with no object is a transient failure, not an object. Measured
      # against openrouter:ling on one transcript: three identical calls, one object and two
      # answers of thinking and text with no tool call; the retry around this takes the next.
      case ReqLLM.Response.object(response) do
        nil -> {:error, Error.transient(:no_object)}
        object -> {:ok, object, Mapping.normalise_usage(ReqLLM.Response.usage(response))}
      end
    end
  rescue
    e -> {:error, Mapping.classify(e)}
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
         {:ok, %{embedding: vectors, usage: usage}} <-
           Mapping.wrap(ReqLLM.embed(spec, texts, embed_opts)) do
      vectors =
        if texts |> length() == 1 and is_list(hd(vectors)) == false, do: [vectors], else: vectors

      {:ok, vectors, Mapping.normalise_usage(usage)}
    end
  rescue
    e -> {:error, Mapping.classify(e)}
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

  @doc false
  @spec context(Request.t()) :: ReqLLM.Context.t()
  def context(%Request{system: system, messages: messages}) do
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
end
