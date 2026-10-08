# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop.Tauri do
  @moduledoc """
  The Tauri shell (slice 100), over the channel `ex_tauri` keeps between the Rust window and this
  BEAM: the socket `ExTauri.ShutdownManager` listens on for the heartbeat, which carries
  newline-delimited JSON both ways. A command goes out as
  `{"type":"command","name":...,"payload":...}`; the shell's events come back to subscribers of
  `ExTauri.Desktop.subscribe/0` as `{:ex_tauri_event, name, payload}`, and
  `Trinity.Desktop.Shell` is the subscriber.

  **The one private shape this relies on** (NOTES D7): `ExTauri.Desktop` exposes only `notify/2`
  and `set_tray/1`, and both are `GenServer.call(ExTauri.ShutdownManager, {:desktop_command, name,
  payload})` underneath. The commands this slice adds use that same message. It is a private shape
  of a pinned `ex_tauri` 0.2.0; this module is the one place that knows it, and
  `test/trinity/desktop_test.exs` drives a real manager over its socket so an upgrade that changes
  it fails there.

  The Rust side of every command is `src-tauri/src/main.rs`'s `handle_channel_command/2`.
  """
  @behaviour Trinity.Desktop

  alias Trinity.Desktop.Shell

  @dialog_timeout_ms 300_000

  @impl true
  def available? do
    Process.whereis(channel()) != nil and
      match?(%{trusted: true}, safe_status(Shell))
  end

  @impl true
  def notify(title, opts) when is_binary(title) do
    with {:ok, path} <- app_path(Keyword.get(opts, :path, "/")) do
      command("notify", %{title: title, body: Keyword.get(opts, :body, ""), path: path})
    end
  end

  @impl true
  def tray_update(status), do: command("set_tray", tray_spec(status))

  @impl true
  def open_dialog(opts) do
    shell = Keyword.get(opts, :shell, Shell)
    timeout = Keyword.get(opts, :timeout, @dialog_timeout_ms)

    payload = %{
      kind: opts |> Keyword.get(:kind, :folder) |> to_string(),
      title: Keyword.get(opts, :title, "")
    }

    Shell.request(shell, "open_dialog", payload, timeout)
  end

  @impl true
  def show_window, do: command("show_window", %{})

  @impl true
  def focus_path(path) do
    with {:ok, path} <- app_path(path), do: command("show_window", %{path: path})
  end

  @impl true
  def open_path(path) when is_binary(path), do: command("open_path", %{path: path})

  @impl true
  def set_hotkey(accelerator), do: command("set_hotkey", %{accelerator: accelerator})

  @impl true
  def set_autostart(enabled) when is_boolean(enabled),
    do: command("set_autostart", %{enabled: enabled})

  @impl true
  def quit, do: command("quit", %{})

  @doc """
  The tray menu a status becomes: a status line that cannot be clicked, then Show, New session,
  Pause (or Resume) gateways, Open data folder and Quit. The ids are what
  `Trinity.Desktop.Shell` acts on when a `tray_menu_click` event names one.
  """
  @spec tray_spec(Trinity.Desktop.tray_status()) :: map()
  def tray_spec(status) do
    pending = Map.get(status, :pending, 0)
    thinking = Map.get(status, :thinking, 0)

    activity =
      case Map.get(status, :status, :idle) do
        :thinking -> "Thinking (#{thinking})"
        _ -> "Idle"
      end

    approvals =
      case pending do
        0 -> "no pending approvals"
        1 -> "1 pending approval"
        n -> "#{n} pending approvals"
      end

    pause =
      if Map.get(status, :gateways_paused, false), do: "Resume gateways", else: "Pause gateways"

    %{
      tooltip: "Trinity: #{String.downcase(activity)}, #{pending} pending",
      items: [
        %{id: "status", label: "#{activity}, #{approvals}", enabled: false},
        %{id: "show", label: "Show Trinity"},
        %{id: "new_session", label: "New session"},
        %{id: "pause_gateways", label: pause},
        %{id: "open_data_folder", label: "Open data folder"},
        %{id: "quit", label: "Quit Trinity"}
      ]
    }
  end

  @doc """
  Sends one command to the shell. `{:error, :not_running}` when no channel process exists (the
  suite, a headless node), `{:error, :not_connected}` when no shell is attached to it.
  """
  @spec command(String.t(), map()) :: :ok | {:error, term()}
  def command(name, payload) when is_binary(name) and is_map(payload) do
    case Process.whereis(channel()) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          GenServer.call(pid, {:desktop_command, name, payload}, 5_000)
        catch
          :exit, _ -> {:error, :not_running}
        end
    end
  end

  # A window may only be sent to a page of this app: a path, never a URL, so nothing reaching a
  # notification or a tray action can point the window at another origin.
  defp app_path("/" <> rest = path) do
    if String.starts_with?(rest, "/") or String.contains?(path, ["\\", "\n", "\r"]),
      do: {:error, {:not_an_app_path, path}},
      else: {:ok, path}
  end

  defp app_path(other), do: {:error, {:not_an_app_path, other}}

  defp channel,
    do: Application.get_env(:trinity, :desktop, [])[:channel] || ExTauri.ShutdownManager

  defp safe_status(server) do
    Shell.status(server)
  catch
    :exit, _ -> nil
  end
end
