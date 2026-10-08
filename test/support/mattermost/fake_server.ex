# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.FakeServer do
  @moduledoc """
  A Mattermost server for the suite (slice 072), behind Bandit on a loopback port: the REST calls
  the adapter makes and the WebSocket it listens on. What it answers is what a real server
  answered, recorded (`fixtures.json` beside this file); what it does on a reconnect is what a
  real server did when measured (NOTES D11): a socket that offers a known connection id and a
  sequence number gets no new `hello` and a replay from that number.

  A test drives it with `push/2` (a frame to every connected socket, numbered), reads what the
  adapter asked of it with `requests/1` and `posts/1`, and can make it misbehave: refuse the
  token, replay from further back than asked (`replay_from/2`).
  """
  use Agent

  @behaviour Plug

  import Plug.Conn

  @fixtures Path.join(__DIR__, "fixtures.json")

  @doc "The recorded fixtures, decoded."
  def fixtures, do: @fixtures |> File.read!() |> Jason.decode!()

  @doc "The recorded frames with this `event`, in order."
  def frames(event) do
    for raw <- fixtures()["frames"] ++ fixtures()["system_frames"],
        decoded = Jason.decode!(raw),
        decoded["event"] == event,
        do: raw
  end

  @doc """
  Starts a server expecting `token`. Options: `max_post_size:` (a string, as the server sends it).
  """
  def start!(token, opts \\ []) do
    me = fixtures()["rest"]["users_me"]

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          token: token,
          me: me,
          max_post_size: Keyword.get(opts, :max_post_size, "16383"),
          requests: [],
          posts: %{},
          sockets: [],
          connects: [],
          sent: [],
          seq: 0,
          connection_id: random_id(),
          replay_from: nil,
          next_post: 1
        }
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        GenServer.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    %{agent: agent, url: "http://127.0.0.1:#{port}", bot_user_id: me["id"]}
  end

  @doc "Every REST request the adapter made: `{method, path, body}`, oldest first."
  def requests(%{agent: agent}), do: Agent.get(agent, &Enum.reverse(&1.requests))

  @doc "The posts the adapter created or patched: `%{id => message}`, and their creation order."
  def posts(%{agent: agent}), do: Agent.get(agent, & &1.posts)

  @doc "The created posts' bodies, oldest first."
  def created(server) do
    for {"POST", "/api/v4/posts", body} <- requests(server), do: body
  end

  @doc "The query strings of every WebSocket connection made, oldest first."
  def connects(%{agent: agent}), do: Agent.get(agent, &Enum.reverse(&1.connects))

  @doc "Makes the next resume replay from `seq` regardless of what was asked (an overlap)."
  def replay_from(%{agent: agent}, seq), do: Agent.update(agent, &%{&1 | replay_from: seq})

  @doc "Sends a recorded frame to every socket, renumbered as this server's next event."
  def push(%{agent: agent}, raw_frame) do
    frame =
      Agent.get_and_update(agent, fn state ->
        seq = state.seq + 1
        framed = raw_frame |> Jason.decode!() |> Map.put("seq", seq) |> Jason.encode!()
        {{framed, state.sockets}, %{state | seq: seq, sent: [{seq, framed} | state.sent]}}
      end)

    {framed, sockets} = frame
    for pid <- sockets, do: send(pid, {:push, framed})
    framed
  end

  @doc "The connected sockets' pids."
  def sockets(%{agent: agent}), do: Agent.get(agent, & &1.sockets)

  @doc "Closes every socket from the server's side."
  def drop_sockets(%{agent: agent} = server) do
    for pid <- sockets(server), do: send(pid, :drop)
    Agent.update(agent, &%{&1 | sockets: []})
  end

  ## Plug

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    conn = fetch_query_params(conn)
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)
    path = conn.request_path

    cond do
      not Process.alive?(agent) ->
        conn |> send_resp(503, "") |> halt()

      path == "/api/v4/websocket" ->
        websocket(conn, agent)

      true ->
        rest(conn, path, body, agent)
    end
  end

  defp rest(conn, path, body, agent) do
    Agent.update(agent, &%{&1 | requests: [{conn.method, path, body} | &1.requests]})

    if authorised?(conn, agent),
      do: route(conn, conn.method, path, body, agent),
      else: reply(conn, 401, %{"id" => "api.context.session_expired.app_error"})
  end

  defp authorised?(conn, agent) do
    expected = "Bearer " <> Agent.get(agent, & &1.token)
    get_req_header(conn, "authorization") == [expected]
  end

  defp route(conn, "GET", "/api/v4/users/me", _body, agent),
    do: reply(conn, 200, Agent.get(agent, & &1.me))

  defp route(conn, "GET", "/api/v4/config/client", _body, agent),
    do: reply(conn, 200, %{"MaxPostSize" => Agent.get(agent, & &1.max_post_size)})

  defp route(conn, "POST", "/api/v4/posts", body, agent) do
    id = random_id()
    Agent.update(agent, &%{&1 | posts: Map.put(&1.posts, id, body["message"])})
    reply(conn, 201, Map.merge(body, %{"id" => id}))
  end

  defp route(conn, "PUT", "/api/v4/posts/" <> rest, body, agent) do
    [id, "patch"] = String.split(rest, "/")
    Agent.update(agent, &%{&1 | posts: Map.put(&1.posts, id, body["message"])})
    reply(conn, 200, %{"id" => id, "message" => body["message"]})
  end

  defp route(conn, "POST", "/api/v4/actions/dialogs/open", _body, _agent),
    do: reply(conn, 200, %{"status" => "OK"})

  defp route(conn, "POST", "/api/v4/users/me/typing", _body, _agent),
    do: reply(conn, 200, %{"status" => "OK"})

  defp route(conn, _method, _path, _body, _agent), do: reply(conn, 404, %{"id" => "not_found"})

  defp reply(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  # A connection can arrive after the test that owned this server has ended (a socket's backoff
  # outliving it); it is turned away rather than crashing on an agent that is gone.
  defp websocket(conn, agent) do
    if Process.alive?(agent), do: upgrade(conn, agent), else: conn |> send_resp(503, "") |> halt()
  end

  defp upgrade(conn, agent) do
    Agent.update(agent, &%{&1 | connects: [conn.query_string | &1.connects]})

    if authorised?(conn, agent) do
      conn
      |> WebSockAdapter.upgrade(__MODULE__.Socket, {agent, conn.query_params}, timeout: 60_000)
      |> halt()
    else
      conn |> send_resp(401, "") |> halt()
    end
  end

  @doc false
  def random_id do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyz0123456789"
    for _ <- 1..26, into: "", do: <<Enum.random(alphabet)>>
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl WebSock
    def init({agent, query}) do
      me = self()
      Agent.update(agent, &%{&1 | sockets: [me | &1.sockets]})
      state = Agent.get(agent, & &1)

      frames =
        case query do
          %{"connection_id" => id, "sequence_number" => next} when id == state.connection_id ->
            from = state.replay_from || String.to_integer(next)
            Agent.update(agent, &%{&1 | replay_from: nil})

            for {seq, frame} <- Enum.reverse(state.sent), seq >= from, do: {:text, frame}

          _ ->
            hello = %{
              "event" => "hello",
              "data" => %{"connection_id" => state.connection_id},
              "seq" => 0
            }

            [{:text, Jason.encode!(hello)}]
        end

      {:push, frames, agent}
    end

    @impl WebSock
    def handle_in(_frame, agent), do: {:ok, agent}

    @impl WebSock
    def handle_info({:push, frame}, agent), do: {:push, {:text, frame}, agent}
    def handle_info(:drop, agent), do: {:stop, :normal, agent}
    def handle_info(_other, agent), do: {:ok, agent}

    @impl WebSock
    def terminate(_reason, agent) do
      me = self()

      if Process.alive?(agent),
        do: Agent.update(agent, &%{&1 | sockets: List.delete(&1.sockets, me)})

      :ok
    end
  end
end
