# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Outbox do
  @moduledoc """
  What the Telegram adapter sends (slice 071): messages, edits, the typing indicator, and the
  adapter's status for `/gateways`.

  **Escaping happens here, once.** The router hands an adapter two kinds of text: chunks it got
  from `format/2` (a streamed or finished answer) and text it wrote itself (a pairing prompt, a
  command's answer). Both are markdown, and both are converted to MarkdownV2 at this one point, so
  every text is escaped exactly once whichever road it came by. If Telegram still refuses to parse
  one, the same text is sent again without formatting rather than lost.

  **Edits are throttled to one a second per message.** Telegram rate-limits edits, and the router's
  flush interval (700 ms) is the console's, not Telegram's. An edit that comes sooner than a second
  after the last one is held, replaced by any newer text, and sent when the second is up, so the
  final text of a stream is late by at most a second and never dropped. An edit to the text a
  message already shows is not sent at all (Telegram answers it with an error).

  **Typing.** `{:typing, true}` shows "typing..." in the chat and renews it every four seconds
  (Telegram clears it after five) until something is sent to that chat or a minute passes.
  """
  use GenServer

  alias Trinity.Gateways.Telegram
  alias Trinity.Gateways.Telegram.{Client, Markdown}

  require Logger

  @edit_interval_ms 1_000
  @typing_every_ms 4_000
  @typing_for_ms 60_000
  @call_timeout_ms 20_000

  ## API

  @doc "Starts the outbox."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Delivers one outbound instruction to a chat (the adapter's `deliver/2`)."
  @spec deliver(String.t(), term()) :: :ok | {:ok, integer()} | {:error, term()}
  def deliver(chat, outbound),
    do: GenServer.call(__MODULE__, {:deliver, chat, outbound}, @call_timeout_ms)

  @doc "The adapter's status, as the poller last reported it."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Records the adapter's status (the poller's report)."
  @spec report(map()) :: :ok
  def report(status) when is_map(status), do: GenServer.cast(__MODULE__, {:report, status})

  @doc "The edit interval, in milliseconds."
  @spec edit_interval_ms() :: pos_integer()
  def edit_interval_ms, do: @edit_interval_ms

  ## The process

  @impl GenServer
  def init(_opts) do
    status =
      if Client.configured?(),
        do: %{state: :starting, detail: "starting"},
        else: %{state: :idle, detail: "idle: #{Client.token_env()} is not set"}

    {:ok, %{edits: %{}, typing: %{}, status: status}}
  end

  @impl GenServer
  def handle_call({:deliver, chat, outbound}, _from, state) do
    {reply, state} = handle_outbound(chat, outbound, state)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl GenServer
  def handle_cast({:report, status}, state), do: {:noreply, %{state | status: status}}

  @impl GenServer
  def handle_info({:flush_edit, key}, state), do: {:noreply, flush_edit(key, state)}

  # `token` names one run of the indicator, so a renewal left in the mailbox by a run that was
  # stopped cannot start a second chain beside a newer one.
  def handle_info({:typing, chat, token, until}, state) do
    case Map.get(state.typing, chat) do
      {^token, _timer} ->
        if now() < until do
          _ = Client.call("sendChatAction", %{chat_id: chat, action: "typing"})
          timer = Process.send_after(self(), {:typing, chat, token, until}, @typing_every_ms)
          {:noreply, put_in(state.typing[chat], {token, timer})}
        else
          {:noreply, stop_typing(state, chat)}
        end

      _other ->
        {:noreply, state}
    end
  end

  ## Outbound

  defp handle_outbound(chat, {:message, text}, state), do: send_message(chat, text, nil, state)

  defp handle_outbound(chat, {:message, text, buttons}, state),
    do: send_message(chat, text, keyboard(buttons), state)

  defp handle_outbound(chat, {:edit, message_id, text}, state),
    do: {:ok, edit(chat, message_id, text, state)}

  defp handle_outbound(chat, {:typing, true}, state) do
    state = stop_typing(state, chat)
    token = make_ref()
    send(self(), {:typing, chat, token, now() + @typing_for_ms})
    {:ok, put_in(state.typing[chat], {token, nil})}
  end

  defp handle_outbound(chat, {:typing, false}, state), do: {:ok, stop_typing(state, chat)}

  defp send_message(chat, text, markup, state) do
    state = stop_typing(state, chat)

    case String.trim(text) do
      "" ->
        {{:error, :empty}, state}

      _ ->
        # A text longer than one message after escaping (a long command answer: the router's own
        # text is chunked before escaping) goes as several; the first is the one a later edit names.
        [first | rest] = Telegram.format(text, Telegram.capabilities())
        reply = post_message(chat, first, if(rest == [], do: markup))
        for chunk <- rest, do: post_message(chat, chunk, nil)

        case reply do
          {:ok, %{"message_id" => id}} ->
            {{:ok, id}, put_in(state.edits[{chat, id}], %{at: now(), text: first, pending: nil})}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  defp post_message(chat, text, markup) do
    params =
      %{chat_id: chat, text: Markdown.to_markdown_v2(text), parse_mode: "MarkdownV2"}
      |> put_markup(markup)

    case Client.call("sendMessage", params) do
      {:error, {:telegram, 400, description}} = error ->
        if parse_error?(description),
          do: Client.call("sendMessage", put_markup(%{chat_id: chat, text: text}, markup)),
          else: logged(error, "sendMessage")

      {:error, _} = error ->
        logged(error, "sendMessage")

      ok ->
        ok
    end
  end

  defp edit(chat, message_id, text, state) do
    key = {chat, message_id}
    entry = Map.get(state.edits, key, %{at: 0, text: nil, pending: nil})

    cond do
      entry.text == text and entry.pending == nil ->
        state

      entry.pending != nil ->
        # A flush is already scheduled; it will send the newest text.
        put_in(state.edits[key], %{entry | pending: text})

      now() - entry.at >= @edit_interval_ms ->
        put_edit(chat, message_id, text)
        put_in(state.edits[key], %{entry | at: now(), text: text})

      true ->
        Process.send_after(self(), {:flush_edit, key}, entry.at + @edit_interval_ms - now())
        put_in(state.edits[key], %{entry | pending: text})
    end
  end

  defp flush_edit({chat, message_id} = key, state) do
    case Map.get(state.edits, key) do
      %{pending: text} = entry when is_binary(text) ->
        if text != entry.text, do: put_edit(chat, message_id, text)
        put_in(state.edits[key], %{entry | at: now(), text: text, pending: nil})

      _ ->
        state
    end
  end

  defp put_edit(chat, message_id, text) do
    params = %{
      chat_id: chat,
      message_id: message_id,
      text: Markdown.to_markdown_v2(text),
      parse_mode: "MarkdownV2"
    }

    case Client.call("editMessageText", params) do
      {:error, {:telegram, 400, description}} = error ->
        cond do
          description =~ "message is not modified" ->
            :ok

          parse_error?(description) ->
            Client.call("editMessageText", %{chat_id: chat, message_id: message_id, text: text})

          true ->
            logged(error, "editMessageText")
        end

      {:error, _} = error ->
        logged(error, "editMessageText")

      _ok ->
        :ok
    end
  end

  defp keyboard(buttons) do
    %{
      inline_keyboard: [
        for({label, command} <- buttons, do: %{text: label, callback_data: command})
      ]
    }
  end

  defp put_markup(params, nil), do: params
  defp put_markup(params, markup), do: Map.put(params, :reply_markup, markup)

  defp parse_error?(description), do: description =~ "can't parse entities"

  defp stop_typing(state, chat) do
    case Map.pop(state.typing, chat) do
      {nil, _} ->
        state

      {{_token, timer}, typing} ->
        if is_reference(timer), do: Process.cancel_timer(timer)
        %{state | typing: typing}
    end
  end

  # The reason is the client's, which never carries the token or a URL; the text is not logged.
  defp logged({:error, reason} = error, method) do
    Logger.warning("telegram: #{method} failed: #{inspect(reason)}")
    error
  end

  defp now, do: System.monotonic_time(:millisecond)
end
