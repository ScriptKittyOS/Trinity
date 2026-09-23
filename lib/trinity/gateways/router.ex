# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Router do
  @moduledoc """
  The one road between a channel and Trinity (slice 070). An adapter hands it an inbound message
  and it decides, in this order and no other: is this identity admitted (`Identities`), is it
  inside its rate limit, is the text a command (`Commands`), and otherwise whose session does it
  belong to. Then it sends the text to that session and streams the answer back to the channel.

  Why the order matters. An unknown sender reaches the pairing check and stops there: no session
  is created and no model is called for someone who has not been let in, which is docs/07's rule
  rather than an implementation detail. The rate limit sits above the session so a flood costs a
  row lookup and nothing else.

  **Streaming.** The router subscribes to `session:<id>` once per conversation and coalesces
  `{:assistant_delta, _}` into one message it edits while the turn runs, when the adapter can
  edit; a channel that cannot edit is sent the finished message once, because a message per delta
  is unreadable and, on a real platform, rate-limited into oblivion. The turn's final
  `{:assistant_message, _}` is always delivered, so a channel sees the whole answer whatever its
  capabilities.
  """
  use GenServer

  alias Trinity.Gateways.{Adapter, Commands, Format, Identities}
  alias Trinity.Sessions

  require Logger

  @flush_ms 700
  @default_rate [capacity: 20, per_minute: 20]

  @typedoc "What an adapter hands in: who said what, where."
  @type inbound :: %{
          adapter: module(),
          conversation: Adapter.conversation(),
          external_user_id: String.t(),
          text: String.t(),
          display_name: String.t() | nil
        }

  ## The API an adapter uses

  @doc "Starts the router."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  One inbound message. Answers once the message has been placed (the reply arrives on the channel
  as the turn streams), or with why it was refused: `{:error, :pending}` when a pairing code was
  shown instead, `{:error, :revoked}`, `{:error, :rate_limited}`.
  """
  @spec inbound(module(), Adapter.conversation(), String.t(), String.t(), keyword()) ::
          {:ok, :placed | :command | :paired} | {:error, term()}
  def inbound(adapter, conversation, external_user_id, text, opts \\ []) do
    message = %{
      adapter: adapter,
      conversation: conversation,
      external_user_id: external_user_id,
      text: text,
      display_name: Keyword.get(opts, :display_name)
    }

    GenServer.call(__MODULE__, {:inbound, message}, 30_000)
  end

  @doc "The session a conversation is bound to, or nil."
  @spec session_of(module(), Adapter.conversation()) :: String.t() | nil
  def session_of(adapter, conversation),
    do: GenServer.call(__MODULE__, {:session_of, adapter, conversation})

  @doc """
  Binds a conversation to a session that already exists (`/attach`), so the desktop and the
  channel watch one stream. The conversation's own session, if it had one, is left alone.
  """
  @spec attach(module(), Adapter.conversation(), String.t()) :: :ok | {:error, :no_session}
  def attach(adapter, conversation, session_id),
    do: GenServer.call(__MODULE__, {:attach, adapter, conversation, session_id})

  @doc "Sends an outbound instruction to a conversation through its adapter (used by delivery)."
  @spec deliver(module(), Adapter.conversation(), Adapter.outbound()) :: :ok
  def deliver(adapter, conversation, outbound) do
    _ = adapter.deliver(conversation, outbound)
    :ok
  end

  ## The process

  @impl GenServer
  def init(_opts) do
    {:ok, %{conversations: %{}, sessions: %{}, buckets: %{}}}
  end

  @impl GenServer
  def handle_call({:inbound, message}, _from, state) do
    case admit(message) do
      {:ok, :paired} -> route(message, state)
      {:refused, reply, result} -> {:reply, result, say(message, reply, state)}
    end
  end

  def handle_call({:session_of, adapter, conversation}, _from, state),
    do: {:reply, get_in(state.conversations, [key(adapter, conversation), :session_id]), state}

  def handle_call({:attach, adapter, conversation, session_id}, _from, state) do
    case Sessions.get_session(session_id) do
      nil -> {:reply, {:error, :no_session}, state}
      _row -> {:reply, :ok, bind_state(state, adapter, conversation, session_id)}
    end
  end

  # The stream: everything on `session:<id>` for a bound conversation.
  @impl GenServer
  def handle_info({:session, session_id, event}, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:noreply, state}
      conv_key -> {:noreply, stream(event, conv_key, state)}
    end
  end

  def handle_info({:flush, conv_key}, state), do: {:noreply, flush(conv_key, state)}
  def handle_info(_other, state), do: {:noreply, state}

  ## Admission

  defp admit(message) do
    adapter_name = Adapter.name(message.adapter)

    case Identities.admit(adapter_name, message.external_user_id,
           conversation: message.conversation,
           display_name: message.display_name
         ) do
      {:ok, _identity, :paired} ->
        {:ok, :paired}

      {:ok, identity, :pending} ->
        pairing_reply(adapter_name, message, identity)

      {:ok, _identity, :revoked} ->
        {:refused, "This identity is not allowed to use Trinity.", {:error, :revoked}}

      {:error, _changeset} ->
        {:refused, "Something went wrong admitting you.", {:error, :not_admitted}}
    end
  end

  # A pending sender's message is never a message: it is either the code, or it is answered with
  # the prompt again. Nothing else of it is read.
  defp pairing_reply(adapter_name, message, identity) do
    case Identities.pair(adapter_name, message.external_user_id, message.text) do
      {:ok, _paired} ->
        {:refused, "Paired. Say anything and Trinity will answer.", {:ok, :paired}}

      {:error, _reason} ->
        {:refused, prompt_for(identity), {:error, :pending}}
    end
  end

  defp prompt_for(identity) do
    """
    Trinity does not know you yet. Open the desktop app, go to Settings → Gateways, and you will
    see the code #{identity.code}. Send that code here to pair. It lasts #{div(Identities.code_ttl_s(), 60)} minutes.
    """
    |> String.trim()
  end

  ## Routing an admitted message

  defp route(message, state) do
    case take_token(state, message) do
      {:error, state} ->
        {:reply, {:error, :rate_limited},
         say(message, "Too many messages. Wait a moment.", state)}

      {:ok, state} ->
        dispatch(message, state)
    end
  end

  # A command runs for text an outside channel chose, and this process holds every conversation's
  # binding: a command that raises must cost its own message and nothing else. The reason is
  # logged and the channel is told, rather than the router dying and every conversation with it.
  defp dispatch(%{text: "/" <> _} = message, state) do
    {reply, state} = Commands.handle(message, state)
    {:reply, {:ok, :command}, say(message, reply, state)}
  rescue
    error ->
      Logger.error("gateway command failed: #{Exception.message(error)}")
      {:reply, {:error, :command_failed}, say(message, "That command did not work.", state)}
  end

  defp dispatch(message, state) do
    {session_id, state} = session_for(message, state)

    case Sessions.send_user_message(session_id, message.text) do
      {:ok, _} ->
        {:reply, {:ok, :placed}, state}

      {:error, reason} ->
        Logger.warning("gateway: message refused: #{inspect(reason)}")

        {:reply, {:error, reason},
         say(message, "Trinity is busy with the previous message.", state)}
    end
  end

  ## Sessions and binding

  defp session_for(message, state) do
    conv_key = key(message.adapter, message.conversation)

    case get_in(state.conversations, [conv_key, :session_id]) do
      nil ->
        {:ok, row} = create_session(message)
        {row.id, bind_state(state, message.adapter, message.conversation, row.id)}

      session_id ->
        {session_id, state}
    end
  end

  defp create_session(message) do
    Sessions.create_session(%{
      persona_id: Sessions.default_persona().id,
      origin: Adapter.name(message.adapter),
      title: "#{Adapter.name(message.adapter)}:#{message.conversation}",
      origin_ref: %{
        "adapter" => Adapter.name(message.adapter),
        "conversation" => message.conversation,
        "external_user_id" => message.external_user_id
      }
    })
  end

  @doc """
  Binds a conversation to a session, as a state transition. Public because `Commands` runs inside
  this process: a command that called `attach/3` would be this process calling itself, which is a
  deadlock the suite found. Callers outside the process use `attach/3`.
  """
  @spec bind_state(map(), module(), Adapter.conversation(), String.t()) :: map()
  def bind_state(state, adapter, conversation, session_id) do
    conv_key = key(adapter, conversation)
    :ok = Sessions.subscribe(session_id)

    conversation_state = %{
      adapter: adapter,
      conversation: conversation,
      session_id: session_id,
      buffer: "",
      ref: nil,
      timer: nil
    }

    state
    |> put_in([:conversations, conv_key], conversation_state)
    |> put_in([:sessions, session_id], conv_key)
  end

  ## The stream to the channel

  defp stream({:assistant_delta, delta}, conv_key, state) do
    conv = Map.fetch!(state.conversations, conv_key)

    if conv.adapter.capabilities().edits do
      state
      |> put_in([:conversations, conv_key, :buffer], conv.buffer <> delta)
      |> schedule_flush(conv_key)
    else
      state
    end
  end

  defp stream({:assistant_message, message}, conv_key, state) do
    conv = Map.fetch!(state.conversations, conv_key)
    state = cancel_timer(state, conv_key)
    text = message.content || conv.buffer

    for chunk <-
          conv.adapter.format(text, conv.adapter.capabilities()) |> then(&edit_or_send(conv, &1)) do
      chunk
    end

    state
    |> put_in([:conversations, conv_key, :buffer], "")
    |> put_in([:conversations, conv_key, :ref], nil)
  end

  defp stream({:error, reason}, conv_key, state) do
    conv = Map.fetch!(state.conversations, conv_key)

    _ =
      conv.adapter.deliver(
        conv.conversation,
        {:message, "Trinity hit an error: #{inspect(reason)}"}
      )

    state
  end

  defp stream(_event, _conv_key, state), do: state

  # The finished answer: the message being edited becomes the first chunk, the rest are new
  # messages, so a long answer arrives whole on a channel with a length limit.
  defp edit_or_send(conv, [first | rest]) do
    case conv.ref do
      nil -> _ = conv.adapter.deliver(conv.conversation, {:message, first})
      ref -> _ = conv.adapter.deliver(conv.conversation, {:edit, ref, first})
    end

    for chunk <- rest, do: conv.adapter.deliver(conv.conversation, {:message, chunk})
  end

  defp edit_or_send(_conv, []), do: []

  defp schedule_flush(state, conv_key) do
    case get_in(state.conversations, [conv_key, :timer]) do
      nil ->
        timer = Process.send_after(self(), {:flush, conv_key}, @flush_ms)
        put_in(state.conversations[conv_key][:timer], timer)

      _running ->
        state
    end
  end

  defp flush(conv_key, state) do
    case Map.get(state.conversations, conv_key) do
      nil -> state
      %{buffer: ""} -> put_in(state.conversations[conv_key][:timer], nil)
      conv -> flush_buffer(conv, conv_key, state)
    end
  end

  defp flush_buffer(conv, conv_key, state) do
    [partial | _] = conv.adapter.format(conv.buffer, conv.adapter.capabilities())

    ref =
      case conv.ref do
        nil ->
          case conv.adapter.deliver(conv.conversation, {:message, partial}) do
            {:ok, ref} -> ref
            _ -> nil
          end

        ref ->
          _ = conv.adapter.deliver(conv.conversation, {:edit, ref, partial})
          ref
      end

    state
    |> put_in([:conversations, conv_key, :ref], ref)
    |> put_in([:conversations, conv_key, :timer], nil)
  end

  defp cancel_timer(state, conv_key) do
    case get_in(state.conversations, [conv_key, :timer]) do
      nil -> state
      timer -> Process.cancel_timer(timer) && put_in(state.conversations[conv_key][:timer], nil)
    end
  end

  ## Rate limiting: a token bucket per identity, in this process's own state

  defp take_token(state, message) do
    config = Keyword.merge(@default_rate, rate_config())
    capacity = Keyword.fetch!(config, :capacity)
    per_minute = Keyword.fetch!(config, :per_minute)
    bucket_key = {Adapter.name(message.adapter), message.external_user_id}
    now = System.monotonic_time(:millisecond)
    {tokens, last} = Map.get(state.buckets, bucket_key, {capacity, now})
    refilled = min(capacity, tokens + (now - last) * per_minute / 60_000)

    if refilled >= 1 do
      {:ok, put_in(state.buckets[bucket_key], {refilled - 1, now})}
    else
      {:error, put_in(state.buckets[bucket_key], {refilled, now})}
    end
  end

  defp rate_config,
    do: :trinity |> Application.get_env(:gateways, []) |> Keyword.get(:rate_limit, [])

  ## Saying something back without a session

  defp say(message, text, state) do
    caps = message.adapter.capabilities()

    for chunk <- Format.chunk(text, caps.max_length) do
      message.adapter.deliver(message.conversation, {:message, chunk})
    end

    state
  end

  defp key(adapter, conversation), do: {Adapter.name(adapter), conversation}
end
