# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Socket do
  @moduledoc """
  The Mattermost adapter's connection to its server (slice 072): the server's WebSocket, which
  Trinity opens, so nothing here needs the server to reach Trinity.

  **Authenticating.** The token is read through `Trinity.Config.secret/1` each time a connection
  is built and sent as the upgrade request's bearer credential. It could instead be sent after the
  upgrade, in the server's `authentication_challenge`, and never sit in the connection struct; that
  was the first design and it was measured against a live server (slice 072 NOTES, D11): a socket
  authenticated by challenge is not resumable, the server answers a reconnect with a new connection
  id and the messages sent during the gap are lost. So the header it is, and what the token must
  never reach is the log: this module never logs a connection, a request or a raw disconnect
  reason, and AC6's tests crash this process with the token configured and read every line.

  **What it does with an event** is `Events.read/3`'s answer: a post for the bot is marked handled
  in `State` (decision D8: at most once), and handed to `Trinity.Gateways.Router.inbound/5`. Every
  event's sequence number is recorded, so a socket that dies or loses its connection reconnects
  offering the server its connection id and the next number it expects, and the server replays
  what was missed if it still holds it. A replay that overlaps what was already handled is
  dropped by the mark, which is what keeps a consumer crash from answering a message twice.

  **When the server is not there** the socket backs off, doubling from `backoff_ms` to
  `max_backoff_ms`, and keeps trying. It never fails to start: a server that is down must not
  exhaust the gateway supervisor's restart budget and take the node with it.

  **TLS** verifies the server (OTP's trust store, or `cacertfile:`), with TLS 1.2 as the floor.
  `websockex`'s own default is `verify: :verify_none`; it is never used.
  """
  use WebSockex

  alias Trinity.Gateways.Mattermost
  alias Trinity.Gateways.Mattermost.{Client, Events, State}
  alias Trinity.Gateways.Router

  require Logger

  @not_read "Trinity cannot read files sent here yet. Only the text of your message was read."

  @doc "Starts the socket. It answers at once and connects in the background."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    state = %{
      backoff: Keyword.fetch!(opts, :backoff_ms),
      initial_backoff: Keyword.fetch!(opts, :backoff_ms),
      max_backoff: Keyword.fetch!(opts, :max_backoff_ms)
    }

    WebSockex.start_link(conn(), __MODULE__, state,
      name: __MODULE__,
      async: true,
      handle_initial_conn_failure: true
    )
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  # The connection, with the resume point in its query when there is one and the token in its
  # header when there is one. Built afresh on every (re)connect, because the resume point moves
  # and the token is read when used. With no token the upgrade is made without one and
  # `handle_connect/2` closes it once the server has said so.
  defp conn do
    options = State.options()
    uri = URI.parse(options.url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"

    query =
      case State.resume() do
        {id, next} -> URI.encode_query(connection_id: id, sequence_number: next)
        nil -> nil
      end

    url =
      URI.to_string(%URI{
        uri
        | scheme: scheme,
          path: String.trim_trailing(uri.path || "", "/") <> "/api/v4/websocket",
          query: query
      })

    headers =
      case Client.token() do
        {:ok, token} -> [{"Authorization", "Bearer " <> token}]
        {:error, _} -> []
      end

    WebSockex.Conn.new(url, [extra_headers: headers] ++ tls(uri, options))
  end

  defp tls(%URI{scheme: "https", host: host}, options) do
    trust =
      case options.cacertfile do
        nil -> [cacerts: :public_key.cacerts_get()]
        path -> [cacertfile: String.to_charlist(path)]
      end

    [
      insecure: false,
      ssl_options:
        trust ++
          [
            verify: :verify_peer,
            server_name_indication: String.to_charlist(host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ],
            versions: [:"tlsv1.3", :"tlsv1.2"]
          ]
    ]
  end

  defp tls(_uri, _options), do: []

  ## Connecting

  # The server's facts are learned before any frame is read, so the first post of a connection is
  # never read against no facts at all. A server that will not answer is closed on, and the
  # reconnect backs off.
  @impl WebSockex
  def handle_connect(_conn, state) do
    case learn_server() do
      :ok ->
        Logger.info("mattermost: connected")
        State.put_connection({:connected, State.facts().bot_username})
        {:ok, %{state | backoff: state.initial_backoff}}

      {:error, reason} ->
        why = describe(reason)
        Logger.warning("mattermost: connected, but not to a server that will talk: #{why}")
        State.put_connection({:error, why})

        send(self(), :give_up)
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_info(:give_up, state), do: {:close, state}
  def handle_info(_other, state), do: {:ok, state}

  # Who the bot is and how long a post may be, asked on every connect: a server can be upgraded
  # or reconfigured while Trinity runs, and the limit is the server's, not this module's.
  defp learn_server do
    with {:ok, %{"id" => id, "username" => username}} <- Client.me(),
         {:ok, config} <- Client.client_config(),
         {:ok, size} <- max_post_size(config) do
      State.put_facts(%{bot_user_id: id, bot_username: username, max_post_size: size})
    else
      {:ok, _unexpected} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  defp max_post_size(%{"MaxPostSize" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {size, ""} when size > 0 -> {:ok, size}
      _ -> {:error, :no_max_post_size}
    end
  end

  defp max_post_size(_config), do: {:error, :no_max_post_size}

  ## Frames

  @impl WebSockex
  def handle_frame({:text, frame}, state) do
    frame
    |> Events.read(State.facts(), &State.thread?/1)
    |> act(state)
  end

  def handle_frame(_other, state), do: {:ok, state}

  defp act({:hello, connection_id, seq}, state) do
    :ok = State.put_resume(connection_id, seq + 1)
    {:ok, state}
  end

  defp act({:auth, _answer}, state), do: {:ok, state}

  defp act({:post, seq, inbound}, state) do
    advance(seq)
    if State.mark_handled(inbound.post_id), do: hand_on(inbound)
    {:ok, state}
  end

  defp act({:event, seq, _why}, state) do
    advance(seq)
    {:ok, state}
  end

  defp act({:unreadable, _why}, state), do: {:ok, state}

  defp advance(nil), do: :ok

  defp advance(seq) do
    case State.resume() do
      {id, _next} -> State.put_resume(id, seq + 1)
      nil -> :ok
    end
  end

  defp hand_on(inbound) do
    if inbound.follow, do: State.follow_thread(inbound.follow)

    result =
      if inbound.text == "" do
        :no_text
      else
        Router.inbound(Mattermost, inbound.conversation, inbound.user_id, inbound.text,
          display_name: inbound.display_name
        )
      end

    # Files are not carried (decision D9). An admitted sender is told, rather than left to
    # think the file was read; a stranger is not told anything beyond the pairing prompt.
    if inbound.files > 0 and result in [{:ok, :placed}, :no_text] do
      Router.deliver(Mattermost, inbound.conversation, {:message, @not_read})
    end

    :ok
  end

  ## Losing the server

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    why = describe(reason)
    Logger.warning("mattermost: connection lost (#{why}); retrying in #{state.backoff} ms")
    State.put_connection({:error, "connection lost (#{why})"})

    Process.sleep(state.backoff)
    next = min(state.backoff * 2, state.max_backoff)
    {:reconnect, conn(), %{state | backoff: next}}
  end

  # A reason as a short phrase. Never `inspect/1` of a connection or a request: those are
  # structs a later change could put a credential in, and the log is not the place to find out.
  defp describe({:missing_secret, env}), do: "#{env} is not set"
  defp describe({:http, status, nil}), do: "HTTP #{status}"
  defp describe({:http, status, id}), do: "HTTP #{status} #{id}"
  defp describe({:transport, reason}), do: "transport #{reason}"
  defp describe({:local, :normal}), do: "closed here"
  defp describe({:remote, :normal}), do: "closed by the server"
  defp describe({:remote, code, _message}), do: "closed by the server, code #{code}"

  defp describe(%WebSockex.RequestError{code: code}),
    do: "the server answered the upgrade with #{code}"

  defp describe(%WebSockex.ConnError{original: original}) when is_atom(original),
    do: Atom.to_string(original)

  defp describe({:local, _code, _message}), do: "closed here"
  defp describe(%{__exception__: true} = e), do: e.__struct__ |> Module.split() |> Enum.join(".")
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(_reason), do: "unexpected"
end
