# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop.ShellTest do
  @moduledoc """
  Slice 100, line 2: `Trinity.Desktop.Shell`, the process between Trinity and the window. These
  are the Elixir halves of AC2 (the tray's status and actions, the pending count live) and AC3
  (an approval while the window is away is a notification whose click goes to the card), against
  `Trinity.Desktop.Recorder`, which reports every call to this test.

  What a window, a tray host or a notification daemon does with those calls is the Linux run in
  PROOF.md and the manual queue for macOS and Windows. This file proves the calls are made, with
  what, and when.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Desktop.{Recorder, Shell}
  alias Trinity.{Factory, Gateways, Permissions, Settings}

  setup do
    Application.put_env(:trinity, :desktop_recorder, self())
    dir = Path.join(System.tmp_dir!(), "shell-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    settings = Path.join(dir, "settings.json")

    on_exit(fn ->
      Application.delete_env(:trinity, :desktop_recorder)
      Gateways.resume()
      File.rm_rf!(dir)
    end)

    name = :"shell-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Shell, impl: Recorder, name: name, token: "t0ken", settings: settings, data_dir: dir}
      )

    session = Factory.session!()
    {:ok, shell: name, pid: pid, session: session, settings: settings, dir: dir}
  end

  defp away(shell), do: send(shell, {:ex_tauri_event, "window", %{"focused" => false}})
  defp here(shell), do: send(shell, {:ex_tauri_event, "window", %{"focused" => true}})
  defp hello(shell), do: send(shell, {:ex_tauri_event, "hello", %{"token" => "t0ken"}})
  defp click(shell, id), do: send(shell, {:ex_tauri_event, "tray_menu_click", %{"id" => id}})

  defp request!(session) do
    {:ok, approval} = Permissions.request_approval(session.id, "fs_write", %{"path" => "/tmp/x"})
    approval
  end

  test "AC2: the tray is pushed at start, idle with nothing pending" do
    assert_receive {:desktop, :tray_update,
                    [%{status: :idle, pending: 0, gateways_paused: false}]}
  end

  test "AC2: the pending count follows requests, decisions and expiry live", %{
    shell: shell,
    session: s
  } do
    assert_receive {:desktop, :tray_update, [%{pending: 0}]}
    a = request!(s)
    assert_receive {:desktop, :tray_update, [%{pending: 1}]}, 1_000
    _b = request!(s)
    assert_receive {:desktop, :tray_update, [%{pending: 2}]}, 1_000
    {:ok, _} = Permissions.decide_request(a.id, :deny)
    assert_receive {:desktop, :tray_update, [%{pending: 1}]}, 1_000
    # The suite's approvals expire after a second (config/test.exs), which is a decision too: the
    # count reaches zero without anyone clicking.
    assert_receive {:desktop, :tray_update, [%{pending: 0}]}, 3_000
    assert Shell.status(shell).pending == 0
  end

  test "AC3: an approval while the window is away is a notification that leads to its card",
       %{shell: shell, session: s} do
    away(shell)
    a = request!(s)
    assert_receive {:desktop, :notify, [title, opts]}, 1_000
    assert title =~ "Approval"
    assert opts[:path] == "/s/#{s.id}#approval-#{a.id}"
    # The tool's name and nothing of its arguments: a notification is shown, and kept, by the OS.
    assert opts[:body] =~ "fs_write"
    refute opts[:body] =~ "/tmp/x"
  end

  test "AC3: a focused window shows the card itself, so there is no notification", %{
    shell: shell,
    session: s
  } do
    here(shell)
    request!(s)
    assert_receive {:desktop, :tray_update, [%{pending: 1}]}, 1_000
    refute_receive {:desktop, :notify, _}, 200
  end

  test "AC3: muted notifications stay muted", %{shell: shell, session: s, settings: settings} do
    :ok = Settings.put(:notifications_muted, true, path: settings)
    away(shell)
    request!(s)
    assert_receive {:desktop, :tray_update, [%{pending: 1}]}, 1_000
    refute_receive {:desktop, :notify, _}, 200
  end

  test "AC2: New session creates one and shows the window on it", %{shell: shell} do
    hello(shell)
    click(shell, "new_session")
    assert_receive {:desktop, :focus_path, ["/s/" <> id]}, 1_000
    assert %{origin: "desktop"} = Trinity.Sessions.get_session(id)
  end

  test "AC2: Pause gateways pauses them, the tray says so, and a second click resumes", %{
    shell: shell
  } do
    hello(shell)
    click(shell, "pause_gateways")
    # A call is answered after every message sent before it, so the click has been handled.
    assert Shell.status(shell).gateways_paused
    assert Gateways.paused?()
    assert_receive {:desktop, :tray_update, [%{gateways_paused: true}]}, 1_000

    click(shell, "pause_gateways")
    refute Shell.status(shell).gateways_paused
    refute Gateways.paused?()
    # The update after the resume is the last one sent.
    assert %{gateways_paused: false} = last_tray()
  end

  defp last_tray(last \\ nil) do
    receive do
      {:desktop, :tray_update, [tray]} -> last_tray(tray)
    after
      100 -> last
    end
  end

  test "AC2: Open data folder opens the data directory; Show shows; Quit quits", %{
    shell: shell,
    dir: dir
  } do
    hello(shell)
    click(shell, "open_data_folder")
    assert_receive {:desktop, :open_path, [^dir]}, 1_000
    click(shell, "show")
    assert_receive {:desktop, :show_window, []}, 1_000
    click(shell, "quit")
    assert_receive {:desktop, :quit, []}, 1_000
  end

  test "F2: a tray click from a peer that never presented the token does nothing", %{shell: shell} do
    send(shell, {:ex_tauri_event, "hello", %{"token" => "wrong"}})
    click(shell, "quit")
    click(shell, "open_data_folder")
    refute_receive {:desktop, :quit, _}, 200
    refute_receive {:desktop, :open_path, _}, 50
  end

  test "AC2: the tray shows thinking while a session is busy", %{shell: shell, session: s} do
    assert_receive {:desktop, :tray_update, [%{status: :idle}]}
    Trinity.Telemetry.session_transition(s.id, :idle, :thinking)
    assert_receive {:desktop, :tray_update, [%{status: :thinking, thinking: 1}]}, 1_000
    Trinity.Telemetry.session_transition(s.id, :thinking, :idle)
    assert_receive {:desktop, :tray_update, [%{status: :idle, thinking: 0}]}, 1_000
    assert Shell.status(shell).thinking == 0
  end

  test "a finished scheduled task and a gateway message notify while the window is away", %{
    shell: shell
  } do
    away(shell)
    Phoenix.PubSub.broadcast(Trinity.PubSub, "tasks", {:task_run, %{id: "r1", task_id: "t1"}})
    assert_receive {:desktop, :notify, [title, opts]}, 1_000
    assert title =~ "task"
    assert opts[:path] == "/tasks"

    Trinity.Telemetry.gateway_inbound("console", :placed)
    assert_receive {:desktop, :notify, [title, _]}, 1_000
    assert title =~ "console"
  end

  test "a command the shell could not carry out is logged", %{shell: shell} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          shell,
          {:ex_tauri_event, "error", %{"message" => "Failed to change launch at login"}}
        )

        _ = Shell.status(shell)
      end)

    assert log =~ "the shell reported: Failed to change launch at login"
  end

  test "after hello the shell is given the saved hotkey and launch-at-login setting", %{
    shell: shell,
    settings: settings
  } do
    :ok = Settings.put(:hotkey, "CommandOrControl+Shift+T", path: settings)
    :ok = Settings.put(:autostart, true, path: settings)
    hello(shell)
    assert_receive {:desktop, :set_hotkey, ["CommandOrControl+Shift+T"]}, 1_000
    assert_receive {:desktop, :set_autostart, [true]}, 1_000
    assert Shell.status(shell).trusted
  end
end
