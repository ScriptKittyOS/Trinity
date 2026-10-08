# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost do
  @moduledoc """
  The Mattermost adapter (slice 072): direct messages and channel mentions in, streamed replies by
  editing the bot's own post, approvals answered through an interactive dialog, one slash command,
  and the scheduler's gateway delivery out.

  Run like every gateway (slice 071): named on `TRINITY_GATEWAYS` (`mattermost`) from the
  `available:` list, or listed in `config :trinity, :gateways, adapters:`. Its own options are
  `config :trinity, :mattermost, url: …, callback_url: …` (`config/runtime.exs` sets them from
  `MATTERMOST_URL` and `MATTERMOST_CALLBACK_URL`), with whatever its child spec is given over them.
  Named with no `url` it starts idle and `/gateways` says why, rather than failing the node's boot.

  The bot token is read through `Trinity.Config.secret/1` from `MATTERMOST_BOT_TOKEN` (or the
  variable `token_env:` names) each time a request or a connection is built, and never logged. The
  one place it outlives a call is the socket's connection, which needs it to reconnect resumably
  (`Socket`'s moduledoc says why that was measured rather than assumed).

  **Which way the network goes.** Messages arrive over the server's WebSocket, which Trinity opens,
  so a server Trinity can reach is all it takes to talk. The server never has to reach Trinity for
  that. Only the interactive controls do: a button press, a dialog submission and the slash
  command are HTTP requests the server makes to `callback_url`. Without a `callback_url` the
  adapter still carries messages and renders approvals as text, and says `buttons: false`.

  **What it decides: nothing.** Like every adapter it carries text to `Trinity.Gateways.Router`
  and renders what the router gives back. An approval's buttons are 071's shape, a label and the
  command a press sends back; here they become the options of one dialog, and the option chosen is
  handed to the router as that command, typed by the person who chose it. The identity check, the
  rate limit, the channel cap and `Trinity.Permissions` see it exactly as they see a typed answer.

  The process tree, `:rest_for_one`: `State` (an ETS table of what has to outlive a dropped
  connection: the server's facts, the resume point, the posts already handled, the callback key),
  then `Socket`. A socket that dies is restarted and resumes; a `State` that dies takes the socket
  with it, because a socket without its table would answer posts twice.
  """
  @behaviour Trinity.Gateways.Adapter

  use Supervisor

  alias Trinity.Gateways.Cap

  alias Trinity.Gateways.Mattermost.{
    Callbacks,
    Client,
    Conversation,
    Format,
    Options,
    Socket,
    State
  }

  alias Trinity.Permissions.Approval

  ## The process

  @doc """
  Starts the adapter's tree: `config :trinity, :mattermost` with `opts` over it, validated by
  `Options` (a malformed value raises; a missing `url` does not, it leaves the adapter idle).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts =
      :trinity
      |> Application.get_env(:mattermost, [])
      |> Keyword.merge(opts)
      |> Options.validate!()

    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Trinity.Gateways.Adapter
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  @impl Supervisor
  def init(opts) do
    socket = if opts[:url], do: [{Socket, opts}], else: []
    Supervisor.init([{State, opts}] ++ socket, strategy: :rest_for_one)
  end

  ## The behaviour

  @doc """
  What this server lets a message be. `max_length` is the server's own `MaxPostSize`, read on
  every connect (D10 in the slice's notes); `buttons` is whether the server can reach Trinity to
  press one.
  """
  @impl Trinity.Gateways.Adapter
  def capabilities do
    %{
      markdown: true,
      images: false,
      buttons: State.callback_url() != nil,
      edits: true,
      max_length: State.max_post_size()
    }
  end

  @impl Trinity.Gateways.Adapter
  def deliver(conversation, outbound) do
    with {:ok, where} <- Conversation.parse(conversation) do
      send_outbound(where, outbound)
    end
  end

  defp send_outbound(where, {:message, text}), do: create(where, text, %{})

  defp send_outbound(where, {:message, text, buttons}) do
    props =
      case State.callback_url() do
        url when is_binary(url) and buttons != [] ->
          Format.button_props(buttons, where, text, url)

        _ ->
          %{}
      end

    create(where, text, props)
  end

  defp send_outbound(_where, {:edit, post_id, text}) do
    with :ok <- Conversation.check_id(post_id),
         {:ok, _} <- Client.patch_post(post_id, %{"message" => text}) do
      :ok
    end
  end

  defp send_outbound(where, {:typing, true}) do
    with {:ok, _} <- Client.typing(where.channel_id, where.root_id), do: :ok
  end

  defp send_outbound(_where, {:typing, false}), do: :ok

  defp create(where, text, props) do
    body =
      %{"channel_id" => where.channel_id, "message" => text, "root_id" => where.root_id || ""}
      |> then(fn body -> if props == %{}, do: body, else: Map.put(body, "props", props) end)

    case Client.create_post(body) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  @impl Trinity.Gateways.Adapter
  defdelegate format(text, capabilities), to: Format

  @doc """
  An approval in Mattermost's words, and, when the server can call back and the channel may
  answer this tier, the two answers as buttons carrying the full id (slice 071's shape, and its
  finding F2: a short id can name two requests). The router offers them only where the cap
  allows; this checks too, so an adapter never draws a control that can only be refused.
  """
  @impl Trinity.Gateways.Adapter
  def render_approval(%Approval{} = approval, capabilities) do
    {:message, text} = Format.render_approval(approval, capabilities)

    if capabilities.buttons and Cap.allows?(__MODULE__, approval.risk) do
      {:message, text,
       [{"Approve once", "/approve " <> approval.id}, {"Deny", "/deny " <> approval.id}]}
    else
      {:message, text}
    end
  end

  @impl Trinity.Gateways.Adapter
  defdelegate callback(kind, params), to: Callbacks, as: :handle

  @doc """
  What `/gateways` shows (slice 071's optional `status/0`): connected to which server as whom,
  idle and why, or the last thing that went wrong, in words with no credential in them.
  """
  @impl Trinity.Gateways.Adapter
  @spec status() :: %{state: atom(), detail: String.t()}
  def status do
    case State.options() do
      nil -> %{state: :stopped, detail: "not started"}
      %{url: nil} -> %{state: :idle, detail: "idle: MATTERMOST_URL is not set"}
      options -> running_status(options)
    end
  end

  defp running_status(options) do
    case {Trinity.Config.secret(options.token_env), State.connection()} do
      {{:error, _}, _} ->
        %{state: :idle, detail: "idle: #{options.token_env} is not set"}

      {_, {:connected, username}} ->
        %{state: :connected, detail: "connected to #{options.url} as @#{username}"}

      {_, {:error, why}} ->
        %{state: :error, detail: "#{options.url}: #{why}"}

      {_, nil} ->
        %{state: :connecting, detail: "connecting to #{options.url}"}
    end
  end
end
