# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client.Transport.Stdio do
  @moduledoc """
  The stdio transport (slice 060): the configured command as a child on a Port, one JSON
  message per line each way, answers correlated to requests by id. This GenServer owns the
  Port; the client process owns this GenServer and is told when the child exits. The child's
  environment is the process basics (`kept_variables/0`) and the variables `env_refs` names
  (read here, at start, never stored); everything else this VM holds, provider keys first,
  is unset for the child. Its stderr is the VM's, so what the child logs reaches the
  terminal and never the wire.
  A line longer than 1 MiB ends the connection, as the core's own stdio transport bounds
  its lines.
  """
  @behaviour Trinity.MCP.Client.Transport

  use GenServer

  require Logger

  alias Trinity.MCP.Client.Wire
  alias Trinity.MCP.ServerConfig

  @max_line_bytes 1_048_576
  @default_timeout 30_000

  @impl Trinity.MCP.Client.Transport
  def connect(%ServerConfig{transport: "stdio"} = config, owner, opts) do
    GenServer.start_link(__MODULE__, {config, owner, opts})
  end

  @impl Trinity.MCP.Client.Transport
  def request(pid, %{"id" => id} = request, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      GenServer.call(pid, {:request, id, Wire.encode(request), timeout}, timeout + 100)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {reason, _} -> {:error, {:transport_down, reason}}
    end
  end

  @impl Trinity.MCP.Client.Transport
  def notify(pid, request, _opts) do
    GenServer.call(pid, {:notify, Wire.encode(request)})
  catch
    :exit, {reason, _} -> {:error, {:transport_down, reason}}
  end

  @impl Trinity.MCP.Client.Transport
  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc "The child's OS pid (a test kills it to prove the reconnect)."
  @spec os_pid(pid()) :: integer() | nil
  def os_pid(pid) do
    GenServer.call(pid, :os_pid)
  catch
    :exit, _ -> nil
  end

  ## GenServer

  @impl GenServer
  def init({config, owner, _opts}) do
    case System.find_executable(config.command) do
      nil ->
        {:stop, {:command_not_found, config.command}}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :hide,
            {:line, @max_line_bytes},
            {:args, config.args},
            {:env, env(config.env_refs)}
          ])

        {:ok, %{port: port, owner: owner, pending: %{}, partial: [], config: config}}
    end
  end

  # A port's `env:` adds to the inherited environment and never replaces it, so the child
  # would see every variable this VM has, provider keys included. Every inherited variable
  # outside the allow list is unset by name (`{name, false}`), on every OS; what remains is
  # the process basics (PATH, HOME, the locale, the temp dir) and the variables the row
  # names. A name with no value is skipped and logged.
  @kept ~w(PATH HOME LANG LC_ALL TMPDIR TMP TEMP SYSTEMROOT SYSTEMDRIVE USERPROFILE)

  defp env(refs) do
    keep = MapSet.new(@kept ++ refs)

    unset =
      for {name, _} <- System.get_env(), name not in keep, do: {String.to_charlist(name), false}

    passed =
      Enum.flat_map(refs, fn ref ->
        case System.get_env(ref) do
          nil ->
            Logger.warning("mcp stdio: environment variable #{ref} is not set; not passed")
            []

          value ->
            [{String.to_charlist(ref), String.to_charlist(value)}]
        end
      end)

    unset ++ passed
  end

  @doc "The variables a child keeps from this VM's environment beside the row's `env_refs`."
  @spec kept_variables() :: [String.t()]
  def kept_variables, do: @kept

  @impl GenServer
  def handle_call({:request, id, line, timeout}, from, state) do
    Port.command(state.port, [line, ?\n])
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    {:noreply, put_in(state.pending[id], {from, timer})}
  end

  def handle_call({:notify, line}, _from, state) do
    Port.command(state.port, [line, ?\n])
    {:reply, :ok, state}
  end

  def handle_call(:os_pid, _from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} -> {:reply, os_pid, state}
      _ -> {:reply, nil, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary(Enum.reverse([chunk | state.partial]))
    {:noreply, handle_line(line, %{state | partial: []})}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | partial: [chunk | state.partial]}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:shutdown, {:exit_status, status}}, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # A line is an answer to a pending id, a notification (no id) for the owner, or noise
  # (undecodable, or an id nobody waits on) that is logged and dropped: the child's stdout
  # is the wire, and a server that prints there has broken it, which is the server's fault.
  defp handle_line(line, state) do
    case Wire.decode(line) do
      {:ok, %{"id" => id} = message} when is_map_key(state.pending, id) ->
        {{from, timer}, pending} = Map.pop(state.pending, id)
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, message})
        %{state | pending: pending}

      {:ok, %{"method" => method} = message} when not is_map_key(message, "id") ->
        send(state.owner, {:mcp_notification, self(), method, Map.get(message, "params", %{})})
        state

      {:ok, other} ->
        Logger.warning(
          "mcp stdio #{state.config.name}: unmatched message #{inspect(other, limit: 20)}"
        )

        state

      {:error, reason} ->
        Logger.warning("mcp stdio #{state.config.name}: undecodable line (#{inspect(reason)})")
        state
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    for {_id, {from, timer}} <- state.pending do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, {:transport_down, reason}})
    end

    send(state.owner, {:mcp_transport_down, self(), reason})
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  catch
    _, _ -> :ok
  end
end
