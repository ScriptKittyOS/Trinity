# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry.Activity do
  @moduledoc """
  A bounded, in-memory record of recent events, for the Activity page (slice 090).

  **Bounded, because an unbounded event buffer is a memory leak with a nice name.** It keeps the
  last `limit/0` events and drops the oldest; nothing here is durable and nothing here is meant to
  be. What must survive a restart is a receipt (slice 024) or a usage row (slice 011), and both are
  written to disk by the code that caused them rather than by a listener.

  **It holds what the catalogue allows and nothing else.** The events themselves carry no prompt
  text, no completion text and no tool arguments (`docs/telemetry.md`), so neither does this. That
  is worth stating because an activity feed is exactly the feature that tempts someone to enrich a
  record with "just the first line of the message", and the place to refuse that is here, where the
  refusal is visible, rather than in review.

  It is a `GenServer` rather than an ETS table so that the handler's work is bounded by a mailbox
  it cannot outrun: a telemetry handler runs **in the process that emitted the event**, and doing
  real work there would put this module's cost on the turn's latency.
  """

  use GenServer

  alias Trinity.Telemetry

  @handler "trinity-activity"
  @limit 200

  @type entry :: %{
          at: DateTime.t(),
          event: [atom()],
          measurements: map(),
          metadata: map()
        }

  @doc "How many events are kept."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The recent events, newest first.

  Options: `:session_id` and `:event` (a prefix, so `[:trinity, :tool]` matches both the start and
  the stop).
  """
  @spec recent(keyword()) :: [entry()]
  def recent(opts \\ []) do
    GenServer.call(__MODULE__, :recent)
    |> filter_session(opts[:session_id])
    |> filter_event(opts[:event])
  catch
    :exit, _ -> []
  end

  @doc "Empties the buffer. For tests, and for a person who wants the page to start again."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    # Attached here rather than in the application so the handler's lifetime is this process's: a
    # handler that outlives its target sends to a dead pid on every event for the rest of the run.
    :telemetry.attach_many(@handler, Telemetry.catalogue(), &__MODULE__.handle/4, nil)
    {:ok, %{entries: []}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler)
    :ok
  end

  @doc false
  # Runs in the emitting process. It does one `send` and nothing else, on purpose: a handler that
  # did real work here would charge it to whatever turn happened to emit the event.
  def handle(event, measurements, metadata, _config) do
    send(__MODULE__, {:event, event, measurements, metadata, DateTime.utc_now()})
    :ok
  rescue
    # A send to a name that is not registered raises; an unstarted buffer must not break a turn.
    _ -> :ok
  end

  @impl true
  def handle_info({:event, event, measurements, metadata, at}, state) do
    entry = %{at: at, event: event, measurements: measurements, metadata: metadata}
    {:noreply, %{state | entries: Enum.take([entry | state.entries], @limit)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:recent, _from, state), do: {:reply, state.entries, state}
  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | entries: []}}

  defp filter_session(entries, nil), do: entries

  defp filter_session(entries, session_id),
    do: Enum.filter(entries, &(&1.metadata[:session_id] == session_id))

  defp filter_event(entries, nil), do: entries

  defp filter_event(entries, prefix) when is_list(prefix),
    do: Enum.filter(entries, &List.starts_with?(&1.event, prefix))
end
