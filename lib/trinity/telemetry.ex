# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry do
  @moduledoc """
  The events Trinity emits, and the only place that names them (slice 090).

  The catalogue, with each event's measurements and metadata, is `docs/telemetry.md`, and it was
  written before this module. An event name is an interface: once something attaches a handler to
  `[:trinity, :llm, :call, :stop]`, renaming it breaks that consumer **silently**, because a handler
  attached to a name that no longer fires simply never runs. Nothing here invents a name that the
  document does not already carry.

  ## What never enters an event

  No prompt text, no completion text, no key material, no tool arguments. Handlers are attached by
  anything in the VM and their output reaches dashboards, logs and exporters, which is the path by
  which a conversation ends up somewhere nobody meant. Events carry identifiers, counts and
  durations; the content stays in the database behind the permission model.

  `span/3` and the emitters below take only what the catalogue lists, so passing content would
  require changing this module, which is the point of routing every event through it.
  """

  ## Trace context. A turn's events share a trace id and name their parent, so the events of one
  ## turn can be assembled into a tree without a tracing library being present.

  @trace_key {__MODULE__, :trace}

  @doc """
  Runs `fun` with a fresh trace id in the calling process, so every event emitted under it shares
  one and nests beneath it.

  **Why the tree carries this rather than a tracing library.** The events are the durable
  interface; an exporter is one consumer of them. Building the linkage here means a turn is already
  a tree, in the buffer and on the page, with no dependency; and it means a later OpenTelemetry
  bridge is a pure export step that changes no emitter, because the parentage it needs is already
  in the metadata.
  """
  @spec trace(keyword(), (-> result)) :: result when result: term()
  def trace(opts \\ [], fun) when is_function(fun, 0) do
    previous = Process.get(@trace_key)
    trace_id = Keyword.get(opts, :trace_id) || new_id()
    Process.put(@trace_key, %{trace_id: trace_id, span_id: new_id(), parent_id: nil})

    try do
      fun.()
    after
      if previous, do: Process.put(@trace_key, previous), else: Process.delete(@trace_key)
    end
  end

  @doc "The trace context in force in this process, or `nil` outside a trace."
  @spec context() :: map() | nil
  def context, do: Process.get(@trace_key)

  @doc "A fresh trace id, for a caller that starts a trace in one process and runs it in another."
  @spec new_trace_id() :: String.t()
  def new_trace_id, do: new_id()

  defp new_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Every event carries the trace it happened in, when there is one. Absent outside a trace rather
  # than invented: a span with a trace id nothing else shares is noise wearing a tree's clothes.
  defp with_trace(metadata) do
    case context() do
      nil -> metadata
      %{trace_id: t, span_id: s} -> Map.merge(metadata, %{trace_id: t, parent_span_id: s})
    end
  end

  @doc """
  Wraps work in `:start` and `:stop`/`:exception` events under `[:trinity | name]`.

  `:telemetry.span/3`'s shape rather than a bare `execute`, so a failed operation is never silently
  missing from the count of completed ones: a dashboard that counts only successes reports a healthy
  system right up until somebody looks at the logs.
  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(name, metadata, fun) when is_list(name) and is_map(metadata) do
    metadata = with_trace(Map.put(metadata, :span_id, new_id()))

    :telemetry.span([:trinity | name], metadata, fn ->
      {result, stop_meta} = fun.()
      {result, Map.merge(metadata, stop_meta)}
    end)
  end

  @doc "Emits one event with the measurements and metadata the catalogue lists for it."
  @spec emit([atom()], map(), map()) :: :ok
  def emit(name, measurements, metadata) when is_list(name) do
    :telemetry.execute([:trinity | name], measurements, with_trace(metadata))
  end

  ## The emitters. One function per catalogue entry, so a call site names an event rather than
  ## assembling one, and a rename is a change here rather than a search.

  @doc "A completed LLM call. `cost_usd` is the registry price, the same figure the ledger stores."
  @spec llm_stop(map()) :: :ok
  def llm_stop(meta) do
    emit(
      [:llm, :call, :stop],
      %{
        duration: meta[:duration] || 0,
        input_tokens: meta[:input_tokens] || 0,
        output_tokens: meta[:output_tokens] || 0,
        cost_usd: meta[:cost_usd] || 0.0
      },
      Map.take(meta, [:model, :provider, :session_id, :kind, :finish_reason])
    )
  end

  @doc "An approval was raised. Names the tool and its tier, never its arguments."
  @spec approval_requested(String.t(), atom() | String.t(), String.t() | nil) :: :ok
  def approval_requested(tool, risk, session_id) do
    emit([:approval, :requested], %{count: 1}, %{tool: tool, risk: risk, session_id: session_id})
  end

  @doc """
  An approval was answered, with how long the person took.

  `waited_ms` is the number that says whether the permission model is usable or merely correct: a
  gate everybody waits four minutes for is a gate people learn to route around.
  """
  @spec approval_decided(String.t(), atom() | String.t(), String.t() | nil, keyword()) :: :ok
  def approval_decided(tool, risk, session_id, opts) do
    emit(
      [:approval, :decided],
      %{count: 1, waited_ms: Keyword.get(opts, :waited_ms, 0)},
      %{
        tool: tool,
        risk: risk,
        session_id: session_id,
        decision: Keyword.get(opts, :decision),
        basis: Keyword.get(opts, :basis)
      }
    )
  end

  @doc "A session changed state."
  @spec session_transition(String.t(), atom(), atom()) :: :ok
  def session_transition(session_id, from, to) do
    emit([:session, :transition], %{count: 1}, %{session_id: session_id, from: from, to: to})
  end

  @doc """
  A message arrived at a gateway.

  `outcome` is a closed set on purpose: a counter whose label is free text becomes a cardinality
  problem the first time somebody puts an id in it.
  """
  @spec gateway_inbound(String.t(), atom()) :: :ok
  def gateway_inbound(adapter, outcome)
      when outcome in [:placed, :command, :unpaired, :rate_limited] do
    emit([:gateway, :inbound], %{count: 1}, %{adapter: adapter, outcome: outcome})
  end

  @doc "A message left for a gateway."
  @spec gateway_outbound(String.t(), non_neg_integer()) :: :ok
  def gateway_outbound(adapter, bytes) do
    emit([:gateway, :outbound], %{count: 1, bytes: bytes}, %{adapter: adapter})
  end

  @doc "A budget was exceeded."
  @spec budget_exceeded(atom(), String.t() | nil, float(), float()) :: :ok
  def budget_exceeded(scope, scope_id, spent_usd, limit_usd) do
    emit(
      [:budget, :exceeded],
      %{spent_usd: spent_usd, limit_usd: limit_usd},
      %{scope: scope, scope_id: scope_id}
    )
  end

  @doc "Every event name this module can emit, for the test that holds the catalogue to the code."
  @spec catalogue() :: [[atom()]]
  def catalogue do
    [
      [:trinity, :llm, :call, :start],
      [:trinity, :llm, :call, :stop],
      [:trinity, :llm, :call, :exception],
      [:trinity, :tool, :call, :start],
      [:trinity, :tool, :call, :stop],
      [:trinity, :tool, :call, :exception],
      [:trinity, :approval, :requested],
      [:trinity, :approval, :decided],
      [:trinity, :session, :transition],
      [:trinity, :gateway, :inbound],
      [:trinity, :gateway, :outbound],
      [:trinity, :budget, :exceeded]
    ]
  end
end
