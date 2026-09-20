# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM do
  @moduledoc """
  The one door to a language model. Slice 011.

  Sessions call this and never a provider. A request names a registry model id (or nothing, for
  the default); the registry names the provider module; the call is retried on transient errors;
  a completed call writes a `usage_events` row with cost from the registry price. Events reach
  the caller either through a function (`stream/3`) or as messages to a pid (`stream_to/3`),
  which is what slice 012's Session wants.
  """
  use Boundary, deps: [Trinity], exports: [Error, Event, Request, Provider, Registry]

  alias Trinity.LLM.{Error, Registry, Request, Retry, Usage}

  @type opts :: keyword()

  @doc "Streams events through `emit`, in the calling process. Returns the usage."
  @spec stream(Request.t(), opts(), Trinity.LLM.Provider.emit()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def stream(%Request{} = request, opts \\ [], emit) when is_function(emit, 1) do
    with {:ok, entry, module} <- resolve(request) do
      call(entry, "chat", opts, fn ->
        module.stream(request, provider_opts(entry, opts), emit)
      end)
    end
  end

  @doc """
  Streams events as messages `{:llm_event, ref, event}` to `pid`, then `{:llm_done, ref, result}`.
  Runs in a supervised task so the caller is never blocked; `ref` is returned at once.
  """
  @spec stream_to(Request.t(), opts(), pid()) :: {:ok, reference()} | {:error, term()}
  def stream_to(%Request{} = request, opts \\ [], pid) when is_pid(pid) do
    ref = make_ref()

    with {:ok, _entry, _module} <- resolve(request),
         {:ok, _task} <-
           Task.Supervisor.start_child(Trinity.LLM.TaskSupervisor, fn ->
             result = stream(request, opts, &send(pid, {:llm_event, ref, &1}))
             send(pid, {:llm_done, ref, result})
           end) do
      {:ok, ref}
    end
  end

  @doc "One complete response."
  @spec generate(Request.t(), opts()) :: {:ok, Trinity.LLM.Provider.result()} | {:error, term()}
  def generate(%Request{} = request, opts \\ []) do
    with {:ok, entry, module} <- resolve(request) do
      call(entry, "chat", opts, fn -> module.generate(request, provider_opts(entry, opts)) end)
    end
  end

  @doc "A map validated against a JSON Schema."
  @spec generate_object(Request.t(), map(), opts()) :: {:ok, map()} | {:error, term()}
  def generate_object(%Request{} = request, schema, opts \\ []) when is_map(schema) do
    with {:ok, entry, module} <- resolve(request),
         {:ok, object, _usage} <-
           call(entry, "object", opts, fn ->
             module.generate_object(request, schema, provider_opts(entry, opts))
           end) do
      {:ok, object}
    end
  end

  @doc "One vector per text. `opts[:model]` names the embedding model's registry id."
  @spec embed([String.t()], opts()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(texts, opts \\ []) when is_list(texts) do
    with {:ok, entry} <- Registry.lookup(Keyword.get(opts, :model)),
         {:ok, module} <- Registry.provider_module(entry),
         {:ok, vectors, _usage} <-
           call(entry, "embed", opts, fn -> module.embed(texts, provider_opts(entry, opts)) end) do
      {:ok, vectors}
    end
  end

  @doc "The registry's models."
  @spec models() :: [Registry.entry()]
  def models, do: Registry.models()

  @doc "The registry's default model id."
  @spec default_model() :: String.t() | nil
  def default_model, do: Registry.default_model()

  @doc "A model's capabilities, from its registry entry."
  @spec capabilities(String.t()) :: {:ok, [atom() | {atom(), term()}]} | {:error, term()}
  def capabilities(model_id) do
    with {:ok, entry} <- Registry.lookup(model_id), do: {:ok, entry.caps}
  end

  defp resolve(%Request{model: model}) do
    with {:ok, entry} <- Registry.lookup(model),
         {:ok, module} <- Registry.provider_module(entry) do
      {:ok, entry, module}
    end
  end

  # The entry's keys win: a caller's `:model` is a registry id, the entry's is the provider's
  # own name, and the provider must see the latter. Found by the live suite, where an embed
  # call asked req_llm for a provider named after the registry id.
  defp provider_opts(entry, opts) do
    entry_opts =
      entry |> Map.take([:model, :base_url, :api_key_env, :price, :caps]) |> Map.to_list()

    Keyword.merge(opts, entry_opts)
  end

  # Retry around the provider; on success the usage is recorded. The usage row is written for
  # the call that completed, once, whatever the number of attempts it took.
  defp call(entry, kind, opts, fun) do
    case Retry.run(fun, opts) do
      {:ok, %{usage: usage}} = ok ->
        record(entry, kind, usage, opts)
        ok

      {:ok, usage} = ok when is_map(usage) ->
        record(entry, kind, usage, opts)
        ok

      {:ok, _value, usage} = ok ->
        record(entry, kind, usage, opts)
        ok

      other ->
        other
    end
  end

  defp record(entry, kind, usage, opts) do
    {:ok, _} = Usage.record(entry, kind, usage, Keyword.take(opts, [:session_id]))
  end
end
