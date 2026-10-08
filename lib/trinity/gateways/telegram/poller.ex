# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Poller do
  @moduledoc """
  Long-polling `getUpdates` (slice 071), the default way a bot hears from Telegram.

  One request at a time, held open by Telegram for up to `poll_timeout_s` seconds (50 by
  default) until there is something to say. Each update is processed in `update_id` order, and
  **its offset is persisted before it is routed** (`Trinity.Gateways.Telegram.Offset`), so a
  poller killed at any point resumes after the last update it began and never processes one twice
  (AC5). An update below the stored offset is skipped even if the server hands it out again.

  A failed request (Telegram down, a wrong token, a webhook set on the bot so that `getUpdates` is
  refused) is reported to `/gateways` through the outbox and retried with a backoff that doubles
  to a minute; nothing about it is fatal, and nothing logged carries the token.

  Without `TELEGRAM_BOT_TOKEN` the poller does not start (`:ignore`) and the status says why, so a
  desktop with Telegram configured and no token boots and says so rather than crash-looping.
  """
  use GenServer

  alias Trinity.Gateways.Telegram
  alias Trinity.Gateways.Telegram.{Client, Offset, Outbox, Updates}

  require Logger

  @max_backoff_ms 60_000

  @doc "Starts the poller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    if Client.configured?() do
      send(self(), :poll)
      {:ok, %{offset: Offset.load(Telegram.state_dir()), me: nil, backoff: 0}}
    else
      Logger.warning("telegram: #{Client.token_env()} is not set; the Telegram gateway is idle")
      :ignore
    end
  end

  @impl GenServer
  def handle_info(:poll, %{me: nil} = state) do
    case Client.call("getMe") do
      {:ok, %{"id" => _, "username" => username} = me} ->
        Outbox.report(%{state: :running, detail: "polling as @#{username}"})
        handle_info(:poll, %{state | me: me, backoff: 0})

      {:ok, _other} ->
        retry(state, :unexpected_get_me)

      {:error, reason} ->
        retry(state, reason)
    end
  end

  def handle_info(:poll, state) do
    params =
      %{timeout: Telegram.poll_timeout_s(), allowed_updates: ["message", "callback_query"]}
      |> then(fn p -> if state.offset, do: Map.put(p, :offset, state.offset), else: p end)

    receive_timeout = (Telegram.poll_timeout_s() + 10) * 1_000

    case Client.call("getUpdates", params, receive_timeout: receive_timeout) do
      {:ok, updates} when is_list(updates) ->
        if state.backoff > 0,
          do: Outbox.report(%{state: :running, detail: "polling as @#{state.me["username"]}"})

        state = Enum.reduce(Enum.sort_by(updates, & &1["update_id"]), state, &process/2)
        send(self(), :poll)
        {:noreply, %{state | backoff: 0}}

      {:ok, _other} ->
        retry(state, :unexpected_updates)

      {:error, reason} ->
        retry(state, reason)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The offset is stored first and the update routed second: at most once (NOTES, decision 3).
  defp process(%{"update_id" => id} = update, state) when is_integer(id) do
    if state.offset && id < state.offset do
      state
    else
      :ok = Offset.store(Telegram.state_dir(), id + 1)
      route(update, state.me)
      %{state | offset: id + 1}
    end
  end

  defp process(_malformed, state), do: state

  # One update that fails to route costs that update and not the poller: its offset is already
  # stored, so a crash here would only restart the loop to skip it. The reason is logged; the
  # message text is not.
  defp route(update, me) do
    Updates.route(update, me)
  rescue
    error -> Logger.error("telegram: update not routed: #{inspect(error.__struct__)}")
  catch
    :exit, reason ->
      Logger.error("telegram: update not routed: exit #{inspect(elem_reason(reason))}")
  end

  defp elem_reason({reason, _call}), do: reason
  defp elem_reason(reason), do: reason

  defp retry(state, reason) do
    backoff = min(max(state.backoff * 2, 1_000), @max_backoff_ms)
    Logger.warning("telegram: polling failed (#{inspect(reason)}); retrying in #{backoff} ms")
    Outbox.report(%{state: :error, detail: "error: #{describe(reason)}; retrying"})
    Process.send_after(self(), :poll, backoff)
    {:noreply, %{state | backoff: backoff}}
  end

  defp describe({:telegram, 401, _}), do: "Telegram refused the token (401)"

  defp describe({:telegram, 409, _}),
    do:
      "a webhook is set on this bot, so getUpdates is refused (409); remove it with deleteWebhook"

  defp describe({:telegram, code, description}), do: "Telegram #{code}: #{description}"
  defp describe({:transport, reason}), do: "cannot reach Telegram (#{reason})"
  defp describe(other), do: inspect(other)
end
