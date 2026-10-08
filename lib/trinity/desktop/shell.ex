# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop.Shell do
  @moduledoc """
  The process between Trinity and its window (slice 100): it keeps the tray true, decides when
  something deserves an OS notification, and carries out the tray's actions.

  ## What it listens to

    * `approvals:all` (slice 021): a request adds to the pending count, a decision or an expiry
      takes one away; a request while the window is away is a notification whose click shows the
      window on the approval's card, `/s/<session>#approval-<id>`.
    * `[:trinity, :session, :transition]` (slice 090's catalogue): which sessions are busy, for
      the tray's status.
    * `[:trinity, :gateway, :inbound]` and the scheduler's `tasks` topic: a gateway message or a
      finished scheduled task while the window is away is a notification too.
    * the shell's events (`Trinity.Desktop.Tauri`): `hello`, `window`, `tray_menu_click`,
      `dialog_result`.

  A notification names the tool, the task or the channel and nothing else: the OS shows it and
  keeps it in its notification centre, so no argument, message text or result goes into one.

  ## Whom it believes (finding F2)

  On Windows the channel is a loopback TCP port any local process can connect to (slice 001
  NOTES, F2). The shell therefore starts by sending `hello` with the token it handed this BEAM in
  `TRINITY_SHELL_TOKEN`, compared here in constant time. Until a hello has matched, tray clicks
  and dialog results are ignored and requests are refused with `{:error, :untrusted_channel}`: a
  peer that is not the shell cannot quit the app, open a folder, or put a folder of its choosing
  into the filesystem allowlist. Window focus is believed from anyone; the worst it can do is
  cause or suppress a notification. What this does not close is recorded in NOTES: ex_tauri 0.2.0
  does not tell subscribers when the peer disconnects, so trust lasts until the next hello rather
  than until the connection ends, and any peer can still stop the heartbeat.
  """
  use GenServer

  require Logger

  alias Trinity.{Desktop, Gateways, Permissions, Scheduler, Sessions, Settings}

  @busy [:thinking, :tool_wait, :approval_wait, :compacting]
  @resubscribe_ms 1_000

  @type status :: %{
          pending: non_neg_integer(),
          thinking: non_neg_integer(),
          focused: boolean(),
          trusted: boolean(),
          gateways_paused: boolean()
        }

  ## API

  @doc """
  Starts the process. Options: `:name` (default this module), `:impl` (default
  `Trinity.Desktop.impl/0`), `:token` (default `TRINITY_SHELL_TOKEN`), `:settings` (a settings file
  path; default the one in force), `:data_dir` (what Open data folder opens).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "What the process knows: counts, whether the window has focus, whether the shell is trusted."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Sends a command that the shell answers with an event carrying the same id (`open_dialog`), and
  waits for the answer: `{:ok, paths}`, `{:error, :timeout}`, or `{:error, :untrusted_channel}` before
  the shell has said hello.
  """
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def request(server, name, payload, timeout) do
    GenServer.call(server, {:request, name, payload, timeout}, timeout + 1_000)
  catch
    :exit, _ -> {:error, :no_shell_process}
  end

  @doc false
  # A telemetry handler runs in the emitting process, so it does one `send` and nothing else.
  def handle_telemetry([:trinity, :session, :transition], _m, %{session_id: id, to: to}, pid),
    do: send(pid, {:session_state, id, to})

  def handle_telemetry([:trinity, :gateway, :inbound], _m, %{adapter: adapter, outcome: o}, pid),
    do: send(pid, {:gateway_inbound, adapter, o})

  def handle_telemetry(_event, _m, _meta, _pid), do: :ok

  ## GenServer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ok = Permissions.subscribe(:all)
    :ok = Scheduler.subscribe()

    :ok =
      :telemetry.attach_many(
        {__MODULE__, self()},
        [[:trinity, :session, :transition], [:trinity, :gateway, :inbound]],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    state = %{
      impl: Keyword.get_lazy(opts, :impl, &Desktop.impl/0),
      token: Keyword.get_lazy(opts, :token, fn -> System.get_env("TRINITY_SHELL_TOKEN") end),
      settings: Keyword.take(opts, [:settings]) |> Enum.map(fn {:settings, p} -> {:path, p} end),
      data_dir: Keyword.get_lazy(opts, :data_dir, &Trinity.Paths.data_dir/0),
      pending: MapSet.new(),
      busy: MapSet.new(),
      focused: false,
      trusted: false,
      subscribed: false,
      requests: %{},
      last_tray: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    # Read in a short-lived Task, not in this process. Under the suite's SQL sandbox, still in
    # auto mode while the application boots, the first query a long-lived process makes checks a
    # connection out until that process exits; with the suite's pool of two, this process holding
    # one starved Oban's boot-time migration check of the other (measured: the application failed
    # to start after 90 s, "connection not available"). Outside the suite it costs one Task.
    pending =
      fn -> Permissions.pending(:all) |> MapSet.new(& &1.id) end
      |> Task.async()
      |> Task.await(15_000)

    state = %{state | pending: pending} |> subscribe_channel()
    {:noreply, push_tray(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       pending: MapSet.size(state.pending),
       thinking: MapSet.size(state.busy),
       focused: state.focused,
       trusted: state.trusted,
       gateways_paused: Gateways.paused?()
     }, state}
  end

  def handle_call({:request, _name, _payload, _timeout}, _from, %{trusted: false} = state),
    do: {:reply, {:error, :untrusted_channel}, state}

  def handle_call({:request, name, payload, timeout}, from, state) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    case Desktop.Tauri.command(name, Map.put(payload, :id, id)) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)
        {:noreply, put_in(state.requests[id], {from, timer})}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:approval, :requested, approval}, state) do
    unless MapSet.member?(state.pending, approval.id) do
      notify(
        state,
        "Approval needed",
        "#{approval.tool} is waiting for your decision.",
        "/s/#{approval.session_id}#approval-#{approval.id}"
      )
    end

    {:noreply, push_tray(%{state | pending: MapSet.put(state.pending, approval.id)})}
  end

  def handle_info({:approval, :decided, approval}, state),
    do: {:noreply, push_tray(%{state | pending: MapSet.delete(state.pending, approval.id)})}

  def handle_info({:session_state, id, to}, state) do
    busy = if to in @busy, do: MapSet.put(state.busy, id), else: MapSet.delete(state.busy, id)
    {:noreply, push_tray(%{state | busy: busy})}
  end

  def handle_info({:gateway_inbound, adapter, :placed}, state) do
    notify(
      state,
      "New message on #{adapter}",
      "A conversation on #{adapter} has a new message.",
      "/"
    )

    {:noreply, state}
  end

  def handle_info({:gateway_inbound, _adapter, _outcome}, state), do: {:noreply, state}

  def handle_info({:task_run, _run}, state) do
    notify(state, "A scheduled task finished", "Its result is on the tasks page.", "/tasks")
    {:noreply, state}
  end

  # Events from the shell.
  def handle_info({:ex_tauri_event, "hello", payload}, state) do
    trusted = token_matches?(state.token, payload["token"])

    unless trusted do
      Logger.warning("desktop: a peer on the shell channel presented no valid token; ignoring it")
    end

    state = %{state | trusted: trusted}
    {:noreply, if(trusted, do: state |> push_settings() |> push_tray(true), else: state)}
  end

  def handle_info({:ex_tauri_event, "window", %{"focused" => focused}}, state)
      when is_boolean(focused),
      do: {:noreply, %{state | focused: focused}}

  def handle_info({:ex_tauri_event, "tray_menu_click", %{"id" => id}}, %{trusted: true} = state),
    do: {:noreply, tray_action(id, state)}

  def handle_info({:ex_tauri_event, "dialog_result", %{"id" => id} = p}, %{trusted: true} = state) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, timer}, requests} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, dialog_paths(p["paths"])})
        {:noreply, %{state | requests: requests}}
    end
  end

  # A command the shell could not carry out (a shortcut it could not register, a launch-at-login
  # entry it could not write) comes back as an `error` event; it is logged, not swallowed.
  def handle_info({:ex_tauri_event, "error", %{"message" => message}}, state) do
    Logger.warning("desktop: the shell reported: #{message}")
    {:noreply, state}
  end

  def handle_info({:ex_tauri_event, _name, _payload}, state), do: {:noreply, state}

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, requests} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | requests: requests}}
    end
  end

  def handle_info(:subscribe_channel, state), do: {:noreply, subscribe_channel(state)}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Process.send_after(self(), :subscribe_channel, @resubscribe_ms)
    {:noreply, %{state | subscribed: false, trusted: false}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  ## Actions

  defp tray_action("show", state), do: tap(state, fn s -> s.impl.show_window() end)

  defp tray_action("new_session", state) do
    case Sessions.create_session(%{persona_id: Sessions.default_persona().id, origin: "desktop"}) do
      {:ok, session} -> state.impl.focus_path("/s/#{session.id}")
      {:error, reason} -> Logger.warning("desktop: New session failed: #{inspect(reason)}")
    end

    state
  end

  defp tray_action("pause_gateways", state) do
    if Gateways.paused?(), do: Gateways.resume(), else: Gateways.pause()
    push_tray(state)
  end

  defp tray_action("open_data_folder", state),
    do: tap(state, fn s -> s.impl.open_path(s.data_dir) end)

  defp tray_action("quit", state), do: tap(state, fn s -> s.impl.quit() end)
  defp tray_action(_unknown, state), do: state

  ## Helpers

  defp notify(state, title, body, path) do
    unless state.focused or Settings.get(:notifications_muted, state.settings) do
      state.impl.notify(title, body: body, path: path)
    end

    :ok
  end

  # After a hello: the saved shortcut and launch-at-login, which only the shell can apply.
  defp push_settings(state) do
    settings = Settings.all(state.settings)
    state.impl.set_hotkey(settings.hotkey)
    state.impl.set_autostart(settings.autostart)
    state
  end

  defp push_tray(state, force \\ false) do
    busy = MapSet.size(state.busy)

    tray = %{
      status: if(busy > 0, do: :thinking, else: :idle),
      thinking: busy,
      pending: MapSet.size(state.pending),
      gateways_paused: Gateways.paused?()
    }

    if force or tray != state.last_tray do
      state.impl.tray_update(tray)
      %{state | last_tray: tray}
    else
      state
    end
  end

  defp subscribe_channel(%{impl: Desktop.Tauri, subscribed: false} = state) do
    channel = Application.get_env(:trinity, :desktop, [])[:channel] || ExTauri.ShutdownManager

    with pid when is_pid(pid) <- Process.whereis(channel),
         :ok <- GenServer.call(pid, {:subscribe, self()}) do
      Process.monitor(pid)
      # A shell already attached said hello before this process was listening (this process
      # restarted, or started late); ask it to say it again. With none attached this is
      # `{:error, :not_connected}` and the shell's own hello on connecting is the one that counts.
      _ = Desktop.Tauri.command("hello", %{})
      %{state | subscribed: true}
    else
      _ ->
        Process.send_after(self(), :subscribe_channel, @resubscribe_ms)
        state
    end
  end

  defp subscribe_channel(state), do: state

  defp token_matches?(expected, given)
       when is_binary(expected) and expected != "" and is_binary(given),
       do: byte_size(expected) == byte_size(given) and :crypto.hash_equals(expected, given)

  defp token_matches?(_expected, _given), do: false

  # A dialog's answer is a list of absolute paths; anything else in it is dropped.
  defp dialog_paths(paths) when is_list(paths),
    do: Enum.filter(paths, &(is_binary(&1) and Path.type(&1) == :absolute))

  defp dialog_paths(_), do: []
end
