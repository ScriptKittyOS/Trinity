# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client do
  @moduledoc """
  One process per configured MCP server (slice 060): Trinity's thin driver over the core's
  public functions (ADR-0007 decision 7). It opens the transport, chooses the revision
  (`server/discover` first; the preferred 2026-07-28 if the server lists it, else
  `initialize` at 2025-11-25 if it lists that, else a refusal naming the list), pages
  through `tools/list`, registers every tool it may through `Trinity.MCP.Bridge`, and
  serves calls: a call runs in the caller's process against a lease of the transport
  handle, so one slow tool does not hold the others to the same server.

  What it holds between calls: the listed tools and their schemas, the multi-round-trip
  continuations waiting on an approval (keyed by session and call id, the server's
  `requestState` verbatim), and the health the `/mcp` page shows. A lost transport
  unregisters the tools, backs off (250 ms doubling to 30 s by default) and reconnects;
  `ttlMs` on the list schedules a re-list, and a `notifications/tools/list_changed` from a
  stdio server triggers one.
  """
  use GenServer

  require Logger

  alias Trinity.MCP.{Bridge, ServerConfig}
  alias Trinity.MCP.Client.Wire

  @type status :: :connecting | :ready | :down | :refused

  @default_backoff_ms 250
  @default_max_backoff_ms 30_000
  @default_timeout 30_000
  @default_connect_timeout 15_000

  ## API

  @doc "Starts the client for a configured server; `opts`: `backoff_ms:`, `max_backoff_ms:`, `timeout:`, `transport_opts:`."
  @spec start_link({ServerConfig.t(), keyword()}) :: GenServer.on_start()
  def start_link({%ServerConfig{name: name} = config, opts}),
    do: GenServer.start_link(__MODULE__, {config, opts}, name: via(name))

  @doc false
  def child_spec({%ServerConfig{name: name} = config, opts}) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [{config, opts}]},
      restart: :transient
    }
  end

  @doc "The registry name of a server's client."
  @spec via(String.t()) :: {:via, Registry, {Trinity.Registry, {:mcp_client, String.t()}}}
  def via(name), do: {:via, Registry, {Trinity.Registry, {:mcp_client, name}}}

  @doc "The client's pid for a server name, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(name), do: GenServer.whereis(via(name))

  @doc "What the page shows: status, revision, the tools and their registry names, the last error, the attempts."
  @spec info(String.t() | pid()) :: {:ok, map()} | {:error, :not_running}
  def info(server) do
    case target(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :info)
    end
  end

  @doc "Drops the transport and reconnects now."
  @spec reconnect(String.t() | pid()) :: :ok | {:error, :not_running}
  def reconnect(server) do
    case target(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :reconnect)
    end
  end

  @doc "Re-lists the tools now."
  @spec relist(String.t() | pid()) :: :ok | {:error, :not_running}
  def relist(server) do
    case target(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :relist)
    end
  end

  @doc """
  Calls a tool on a server from the caller's process: the arguments are validated against
  the schema the server listed (through the core's validator), the request built by
  `Trinity.MCP.Client.Wire`, and the answer decoded by the core. With `continuation:` the
  call is the multi-round-trip retry. The answer is the server's whole JSON-RPC message.
  """
  @spec call(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(server, tool, arguments, opts \\ []) when is_map(arguments) do
    with pid when is_pid(pid) <- target(server) || {:error, :server_not_running},
         {:ok, lease} <- GenServer.call(pid, {:lease, tool}),
         :ok <- validate(lease, arguments, opts) do
      request =
        Wire.tools_call(next_id(), tool, arguments, lease.revision,
          continuation: Keyword.get(opts, :continuation)
        )

      lease.transport.request(lease.handle, request,
        schemas: lease.schemas,
        timeout: Keyword.get(opts, :timeout, lease.timeout)
      )
    end
  end

  # A retry carries the arguments the server already validated; validating them again is
  # harmless, so both paths validate.
  defp validate(lease, arguments, _opts), do: Wire.validate_arguments(arguments, lease.schema)

  @doc "Stores a multi-round-trip continuation for a call, to be taken by the retry."
  @spec put_continuation(String.t(), term(), map()) :: :ok | {:error, :not_running}
  def put_continuation(server, key, continuation) do
    case target(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:put_continuation, key, continuation})
    end
  end

  @doc "Takes the continuation stored for a call, if any."
  @spec pop_continuation(String.t(), term()) :: map() | nil
  def pop_continuation(server, key) do
    case target(server) do
      nil -> nil
      pid -> GenServer.call(pid, {:pop_continuation, key})
    end
  end

  defp target(pid) when is_pid(pid), do: pid
  defp target(name) when is_binary(name), do: whereis(name)

  defp next_id, do: System.unique_integer([:positive, :monotonic])

  ## GenServer

  @impl true
  def init({%ServerConfig{} = config, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      config: config,
      opts: opts,
      transport: transport_for(config),
      handle: nil,
      revision: nil,
      status: :connecting,
      tools: %{},
      registered: [],
      continuations: %{},
      last_error: nil,
      attempts: 0,
      backoff_ms: Keyword.get(opts, :backoff_ms, @default_backoff_ms),
      ttl_ms: nil,
      auth_challenge: nil,
      relist_timer: nil,
      reconnect_timer: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  defp transport_for(%ServerConfig{transport: "stdio"}), do: Trinity.MCP.Client.Transport.Stdio
  defp transport_for(%ServerConfig{transport: "http"}), do: Trinity.MCP.Client.Transport.HTTP

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        Logger.info(
          "mcp #{state.config.name}: connected at #{state.revision}, #{map_size(state.tools)} tools"
        )

        {:noreply,
         %{state | status: :ready, attempts: 0, last_error: nil, auth_challenge: nil}
         |> schedule_relist()}

      {:refused, reason, state} ->
        Logger.warning("mcp #{state.config.name}: refused: #{inspect(reason)}")
        {:noreply, %{state | status: :refused, last_error: inspect(reason)}}

      {:error, reason, state} ->
        Logger.warning("mcp #{state.config.name}: connect failed: #{inspect(reason)}")

        state = %{
          state
          | status: :down,
            last_error: inspect(reason),
            auth_challenge: challenge_of(reason)
        }

        {:noreply, retry_later(state)}
    end
  end

  # Slice 062: a 401 whose challenge names a resource metadata URL is what the client role
  # starts from; the page shows "authorize" when this is set.
  defp challenge_of({:discover_failed, {:unauthorized, header}}) do
    case Trinity.MCP.Auth.Client.challenge(header) do
      {:ok, url} -> url
      :error -> nil
    end
  end

  defp challenge_of(_), do: nil

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     {:ok,
      %{
        name: state.config.name,
        status: state.status,
        revision: state.revision,
        tools:
          for {name, tool} <- state.tools, into: %{} do
            {name,
             %{
               registered: Bridge.tool_name(state.config.name, name) in state.registered,
               listed: tool
             }}
          end,
        registered: state.registered,
        last_error: state.last_error,
        attempts: state.attempts,
        transport_os_pid: os_pid(state),
        auth_challenge: state.auth_challenge
      }}, state}
  end

  def handle_call({:lease, tool}, _from, %{status: :ready} = state) do
    case Map.fetch(state.tools, tool) do
      {:ok, listed} ->
        {:reply,
         {:ok,
          %{
            transport: state.transport,
            handle: state.handle,
            revision: state.revision,
            schema: Map.get(listed, "inputSchema", %{"type" => "object"}),
            schemas: schemas(state.tools),
            timeout: Keyword.get(state.opts, :timeout, @default_timeout)
          }}, state}

      :error ->
        {:reply, {:error, {:unknown_tool, tool}}, state}
    end
  end

  def handle_call({:lease, _tool}, _from, state),
    do: {:reply, {:error, {:server_not_ready, state.status}}, state}

  def handle_call({:put_continuation, key, continuation}, _from, state),
    do: {:reply, :ok, put_in(state.continuations[key], continuation)}

  def handle_call({:pop_continuation, key}, _from, state) do
    {value, continuations} = Map.pop(state.continuations, key)
    {:reply, value, %{state | continuations: continuations}}
  end

  defp os_pid(%{handle: nil}), do: nil

  defp os_pid(%{transport: transport, handle: handle}) do
    if function_exported?(transport, :os_pid, 1), do: transport.os_pid(handle), else: nil
  end

  @impl true
  def handle_cast(:reconnect, state) do
    {:noreply, state |> drop(:reconnect) |> Map.put(:attempts, 0), {:continue, :connect}}
  end

  def handle_cast(:relist, %{status: :ready} = state), do: {:noreply, do_relist(state)}
  def handle_cast(:relist, state), do: {:noreply, state}

  @impl true
  def handle_info({:mcp_transport_down, handle, reason}, %{handle: handle} = state) do
    Logger.warning("mcp #{state.config.name}: transport down: #{inspect(reason)}")
    state = drop(%{state | handle: nil}, {:transport_down, reason})
    {:noreply, retry_later(state)}
  end

  def handle_info({:mcp_transport_down, _other, _reason}, state), do: {:noreply, state}

  def handle_info({:mcp_notification, _handle, "notifications/tools/list_changed", _}, state) do
    {:noreply, if(state.status == :ready, do: do_relist(state), else: state)}
  end

  def handle_info({:mcp_notification, _handle, method, _params}, state) do
    Logger.debug("mcp #{state.config.name}: notification #{method} ignored")
    {:noreply, state}
  end

  def handle_info(:relist, %{status: :ready} = state),
    do: {:noreply, do_relist(%{state | relist_timer: nil})}

  def handle_info(:relist, state), do: {:noreply, %{state | relist_timer: nil}}

  def handle_info(:reconnect, state),
    do: {:noreply, %{state | reconnect_timer: nil}, {:continue, :connect}}

  # The stdio transport is linked; its exit reaches here as an EXIT and as the down message.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    unregister_all(state)
    if state.handle, do: state.transport.close(state.handle)
    :ok
  end

  ## Connecting

  defp connect(state) do
    transport_opts = Keyword.get(state.opts, :transport_opts, [])

    with {:ok, handle} <- state.transport.connect(state.config, self(), transport_opts),
         state = %{state | handle: handle},
         {:ok, revision} <- choose_revision(state),
         state = %{state | revision: revision},
         {:ok, tools, ttl} <- list_tools(state) do
      {:ok, register_all(%{state | tools: tools, ttl_ms: ttl})}
    else
      {:refused, reason} -> {:refused, reason, close_handle(state)}
      {:error, reason} -> {:error, reason, close_handle(state)}
    end
  end

  defp close_handle(%{handle: nil} = state), do: state

  defp close_handle(state) do
    state.transport.close(state.handle)
    %{state | handle: nil}
  end

  # `server/discover` is answered by any 2026-07-28 server and by the dual-era core whatever
  # the era; a server that refuses it with "method not found" is a legacy one, and gets
  # `initialize`. The preferred revision wins when listed; the legacy one when that is
  # listed; anything else is a refusal that names the list, and no revision the driver does
  # not speak is tried.
  defp choose_revision(state) do
    case request(state, Wire.discover(next_id()), connect_timeout(state)) do
      {:ok, %{"result" => %{"supportedVersions" => versions}}} when is_list(versions) ->
        pick(state, versions)

      {:ok, %{"error" => %{"code" => -32_601}}} ->
        initialize(state)

      {:ok, %{"error" => %{"code" => -32_022} = error}} ->
        pick(state, List.delete(get_in(error, ["data", "supported"]) || [], Wire.modern()))

      {:ok, %{"error" => error}} ->
        {:error, {:discover_refused, error}}

      {:ok, other} ->
        {:error, {:discover_unreadable, other}}

      {:error, reason} ->
        {:error, {:discover_failed, reason}}
    end
  end

  # The preferred revision when listed, the legacy one when that is, else a refusal naming
  # the list. (A -32022 refusal of the modern opener lists what the server serves; the
  # modern revision is removed from that list before the pick, since the server just said no.)
  defp pick(state, versions) do
    cond do
      Wire.modern() in versions -> {:ok, Wire.modern()}
      Wire.legacy() in versions -> initialize(state)
      true -> {:refused, {:unsupported_revisions, versions}}
    end
  end

  defp initialize(state) do
    client_info = %{"name" => "trinity", "version" => to_string(Application.spec(:trinity, :vsn))}

    case request(state, Wire.initialize(next_id(), client_info), connect_timeout(state)) do
      {:ok, %{"result" => %{"protocolVersion" => version}}} ->
        if version == Wire.legacy() do
          state.transport.notify(state.handle, Wire.initialized(), [])
          {:ok, Wire.legacy()}
        else
          {:refused, {:unsupported_revisions, [version]}}
        end

      {:ok, %{"error" => error}} ->
        {:refused, {:initialize_refused, error}}

      {:ok, other} ->
        {:error, {:initialize_unreadable, other}}

      {:error, reason} ->
        {:error, {:initialize_failed, reason}}
    end
  end

  defp list_tools(state), do: list_tools(state, nil, %{}, 0)

  # Paginated through the cursor the server hands back, opaque to the driver; a list that
  # never ends (a server whose cursor loops) stops at a page bound.
  defp list_tools(_state, _cursor, _acc, 64), do: {:error, :too_many_pages}

  defp list_tools(state, cursor, acc, pages) do
    case request(
           state,
           Wire.tools_list(next_id(), state.revision, cursor),
           connect_timeout(state)
         ) do
      {:ok, %{"result" => %{"tools" => tools} = result}} when is_list(tools) ->
        acc =
          Enum.reduce(tools, acc, fn
            %{"name" => name} = tool, acc when is_binary(name) -> Map.put(acc, name, tool)
            _, acc -> acc
          end)

        case Map.get(result, "nextCursor") do
          next when is_binary(next) and next != "" -> list_tools(state, next, acc, pages + 1)
          _ -> {:ok, acc, Map.get(result, "ttlMs")}
        end

      {:ok, %{"error" => error}} ->
        {:error, {:list_refused, error}}

      {:ok, other} ->
        {:error, {:list_unreadable, other}}

      {:error, reason} ->
        {:error, {:list_failed, reason}}
    end
  end

  defp request(state, request, timeout),
    do:
      state.transport.request(state.handle, request,
        schemas: schemas(state.tools),
        timeout: timeout
      )

  defp connect_timeout(state),
    do: Keyword.get(state.opts, :connect_timeout, @default_connect_timeout)

  defp schemas(tools) do
    for {name, tool} <- tools, into: %{}, do: {name, Map.get(tool, "inputSchema", %{})}
  end

  ## Registration

  defp register_all(state) do
    registered =
      for {name, tool} <- state.tools,
          {:ok, registry_name} <- [Bridge.register(state.config, name, tool)],
          do: registry_name

    %{state | registered: registered}
  end

  defp unregister_all(state) do
    Enum.each(state.registered, &Bridge.unregister/1)
    %{state | registered: []}
  end

  defp do_relist(state) do
    case list_tools(state) do
      {:ok, tools, ttl} ->
        state = unregister_all(state)
        register_all(%{state | tools: tools, ttl_ms: ttl}) |> schedule_relist()

      {:error, reason} ->
        Logger.warning("mcp #{state.config.name}: re-list failed: #{inspect(reason)}")
        schedule_relist(%{state | last_error: inspect(reason)})
    end
  end

  # ttlMs 0 (the core's default) means the list is not to be cached: re-listed on reconnect
  # and on a change notification only, never on a timer that would hammer the server.
  defp schedule_relist(state) do
    if state.relist_timer, do: Process.cancel_timer(state.relist_timer)

    case state.ttl_ms do
      ttl when is_integer(ttl) and ttl > 0 ->
        %{state | relist_timer: Process.send_after(self(), :relist, ttl)}

      _ ->
        %{state | relist_timer: nil}
    end
  end

  ## Losing the server

  defp drop(state, reason) do
    state = unregister_all(state)
    state = close_handle(state)
    if state.relist_timer, do: Process.cancel_timer(state.relist_timer)

    %{
      state
      | status: :down,
        revision: nil,
        tools: %{},
        ttl_ms: nil,
        relist_timer: nil,
        last_error: inspect(reason)
    }
  end

  defp retry_later(state) do
    max = Keyword.get(state.opts, :max_backoff_ms, @default_max_backoff_ms)
    delay = min(state.backoff_ms * Integer.pow(2, min(state.attempts, 16)), max)
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)

    %{
      state
      | attempts: state.attempts + 1,
        reconnect_timer: Process.send_after(self(), :reconnect, delay)
    }
  end
end
