# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ActivityLive do
  @moduledoc """
  `/activity` (slice 090): what Trinity has been doing, as events, with what it has cost.

  The page reads and never writes, like every page in this tree. It shows the bounded buffer
  (`Trinity.Telemetry.Activity`), filterable by session and by kind of event, and the cost totals
  beside it, because "what happened" and "what it cost" are the same question asked twice and
  splitting them across two pages makes a person do the joining.

  **It shows what the events carry, which is deliberately not much.** No prompt text, no completion
  text, no tool arguments (`docs/telemetry.md`). An activity feed is exactly the feature that
  tempts someone to enrich a row with "just the first line of the message"; the refusal lives in
  the catalogue and this page inherits it.
  """
  use TrinityWeb, :live_view

  alias Trinity.Telemetry.{Activity, Costs}

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(page_title: gettext("Activity"), filter: nil, session_filter: "")
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(filter: prefix(kind)) |> load()}
  end

  def handle_event("session", %{"session_id" => id}, socket) do
    {:noreply, socket |> assign(session_filter: String.trim(id)) |> load()}
  end

  def handle_event("clear", _params, socket) do
    Activity.clear()
    {:noreply, load(socket)}
  end

  defp prefix(""), do: nil
  defp prefix("all"), do: nil
  defp prefix(kind), do: [:trinity, String.to_existing_atom(kind)]

  defp load(socket) do
    session_id =
      if socket.assigns.session_filter == "", do: nil, else: socket.assigns.session_filter

    assign(socket,
      entries: Activity.recent(event: socket.assigns.filter, session_id: session_id),
      today: Costs.for_today(),
      total: Costs.total(),
      by_model: Costs.by_model() |> Enum.take(5),
      over: Costs.over(session_id, nil)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="min-w-0 truncate">{gettext("Activity")}</span>
        <span class="font-mono text-meta opacity-70">
          {gettext("today")} ${:erlang.float_to_binary(@today, decimals: 4)}
        </span>
        <span class="font-mono text-meta opacity-50">
          {gettext("all time")} ${:erlang.float_to_binary(@total, decimals: 4)}
        </span>
      </:bar>

      <div class="mx-auto flex w-full max-w-5xl flex-col gap-3 p-4">
        <div
          :for={{scope, spent, limit} <- @over}
          class="rounded-box border border-warning bg-warning/10 px-3 py-2 text-sm"
        >
          {gettext("Over the")} {scope} {gettext("budget")}:
          <span class="font-mono">
            ${:erlang.float_to_binary(spent, decimals: 4)} / ${:erlang.float_to_binary(limit,
              decimals: 2
            )}
          </span>
        </div>

        <section :if={@by_model != []} id="by-model" class="rounded-box border border-base-300 p-3">
          <h2 class="mb-2 text-meta uppercase tracking-wide opacity-70">
            {gettext("Cost by model")}
          </h2>
          <ul class="flex flex-col gap-1">
            <li :for={{model, cost, calls} <- @by_model} class="flex items-center gap-2 text-sm">
              <span class="min-w-0 flex-1 truncate font-mono">{model}</span>
              <span class="font-mono text-meta opacity-60">{calls} {gettext("calls")}</span>
              <span class="font-mono tabular-nums">${:erlang.float_to_binary(cost, decimals: 4)}</span>
            </li>
          </ul>
        </section>

        <div class="flex flex-wrap items-center gap-2">
          <form id="activity-filter" phx-change="filter" class="contents">
            <select
              name="kind"
              class="rounded-field border border-base-300 bg-base-100 px-2 py-1 text-meta"
              aria-label={gettext("Event kind")}
            >
              <option value="all">{gettext("all events")}</option>
              <option :for={k <- ~w(llm tool approval session gateway budget)} value={k}>{k}</option>
            </select>
          </form>
          <form id="activity-session-filter" phx-change="session" class="contents">
            <input
              name="session_id"
              value={@session_filter}
              placeholder={gettext("session id")}
              class="w-72 rounded-field border border-base-300 bg-base-100 px-2 py-1 font-mono text-meta"
            />
          </form>
          <span class="flex-1"></span>
          <button type="button" phx-click="clear" class="btn btn-ghost btn-xs">{gettext("clear")}</button>
        </div>

        <section id="activity" class="rounded-box border border-base-300">
          <p :if={@entries == []} class="p-6 text-center text-sm opacity-60">
            {gettext("Nothing yet. Events appear here as Trinity works.")}
          </p>
          <ul class="divide-y divide-base-300">
            <li :for={e <- @entries} class="flex items-baseline gap-3 px-3 py-1.5 text-sm">
              <span class="font-mono text-meta opacity-50">
                {Calendar.strftime(e.at, "%H:%M:%S")}
              </span>
              <span class="font-mono text-meta">{name(e.event)}</span>
              <span class="min-w-0 flex-1 truncate opacity-80">{summarise(e)}</span>
              <span class="font-mono text-meta opacity-50">{duration(e.measurements)}</span>
            </li>
          </ul>
        </section>

        <p class="text-meta opacity-50">
          {gettext("The last")} {Activity.limit()} {gettext(
            "events, in memory only. Receipts and usage are on disk; this is not."
          )}
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp name([:trinity | rest]), do: Enum.join(rest, ".")
  defp name(other), do: inspect(other)

  # What a row says. Identifiers and outcomes, never content: the events do not carry content and
  # this page does not invent any.
  defp summarise(%{metadata: m}) do
    [m[:tool], m[:model], m[:adapter], m[:decision], m[:outcome], m[:result], m[:to], m[:scope]]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" · ", &to_string/1)
  end

  defp duration(%{duration: d}) when is_integer(d) do
    ms = System.convert_time_unit(d, :native, :millisecond)
    "#{ms} ms"
  end

  defp duration(%{cost_usd: c}) when is_number(c) and c > 0,
    do: "$" <> :erlang.float_to_binary(c / 1, decimals: 4)

  defp duration(_), do: ""
end
