# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.DesktopTest do
  @moduledoc """
  Slice 100, line 1: `Trinity.Desktop`, the seam between Trinity and whatever window it is shown
  in, its `Noop` implementation (headless, CI, `mix phx.server`; AC10's unit half) and its
  `Tauri` implementation.

  The `Tauri` half runs against a real `ExTauri.ShutdownManager` on a Unix socket of its own,
  with this test playing the Rust shell: it connects, reads the newline-delimited JSON the
  implementation writes, and writes events back. That pins the one private shape this slice
  relies on in a pinned `ex_tauri` 0.2.0 (NOTES D7): `{:desktop_command, name, payload}` handled
  by the manager and written as `{"type":"command",...}`. If an upgrade changes it, this fails.
  """
  # DataCase: the shell server reads the pending approvals when it starts.
  use Trinity.DataCase, async: false

  alias Trinity.Desktop

  describe "selection" do
    test "the suite runs on Noop, and Noop answers that there is no shell rather than pretending" do
      assert Desktop.impl() == Desktop.Noop
      refute Desktop.Noop.available?()
      assert {:error, :no_shell} = Desktop.notify("t", body: "b")
      assert {:error, :no_shell} = Desktop.show_window()
      assert {:error, :no_shell} = Desktop.open_dialog(kind: :folder)
      assert {:error, :no_shell} = Desktop.quit()
    end

    test "a process launched by the shell selects Tauri, any other selects Noop" do
      assert Desktop.impl_for(%{"TRINITY_SHELL_TOKEN" => "abc"}) == Desktop.Tauri
      assert Desktop.impl_for(%{}) == Desktop.Noop
      assert Desktop.impl_for(%{"TRINITY_SHELL_TOKEN" => ""}) == Desktop.Noop
      # Headless is headless even if a token leaked into its environment.
      assert Desktop.impl_for(%{"TRINITY_SHELL_TOKEN" => "abc", "TRINITY_MODE" => "headless"}) ==
               Desktop.Noop
    end
  end

  describe "Tauri, over ex_tauri's channel" do
    setup do
      app = "trinity-desktop-test-#{System.unique_integer([:positive])}"
      me = self()

      start_supervised!(
        {ExTauri.ShutdownManager,
         app_name: app, heartbeat_timeout: 60_000, shutdown_fun: fn -> send(me, :shutdown) end}
      )

      path = Path.join(System.tmp_dir!(), "tauri_heartbeat_#{app}.sock")
      {:ok, path: path}
    end

    test "with no shell attached, a command is refused as not connected" do
      assert {:error, :not_connected} = Desktop.Tauri.show_window()
    end

    test "each command reaches the shell as one JSON line in the channel's shape", %{path: path} do
      shell = connect!(path)

      assert :ok =
               Desktop.Tauri.notify("Approval needed", body: "fs_write", path: "/s/1#approval-2")

      assert %{
               "type" => "command",
               "name" => "notify",
               "payload" => %{
                 "title" => "Approval needed",
                 "body" => "fs_write",
                 "path" => "/s/1#approval-2"
               }
             } = read_line!(shell)

      assert :ok = Desktop.Tauri.show_window()
      assert %{"name" => "show_window", "payload" => %{}} = read_line!(shell)

      assert :ok = Desktop.Tauri.focus_path("/s/abc")
      assert %{"name" => "show_window", "payload" => %{"path" => "/s/abc"}} = read_line!(shell)

      assert :ok = Desktop.Tauri.open_path("/data/trinity")

      assert %{"name" => "open_path", "payload" => %{"path" => "/data/trinity"}} =
               read_line!(shell)

      assert :ok = Desktop.Tauri.set_hotkey("CommandOrControl+Shift+Space")

      assert %{
               "name" => "set_hotkey",
               "payload" => %{"accelerator" => "CommandOrControl+Shift+Space"}
             } =
               read_line!(shell)

      assert :ok = Desktop.Tauri.set_autostart(true)
      assert %{"name" => "set_autostart", "payload" => %{"enabled" => true}} = read_line!(shell)

      assert :ok = Desktop.Tauri.quit()
      assert %{"name" => "quit"} = read_line!(shell)
    end

    test "the tray: a status line that cannot be clicked, then the four actions", %{path: path} do
      shell = connect!(path)

      assert :ok =
               Desktop.Tauri.tray_update(%{
                 status: :thinking,
                 thinking: 2,
                 pending: 3,
                 gateways_paused: false
               })

      assert %{"name" => "set_tray", "payload" => payload} = read_line!(shell)
      assert payload["tooltip"] =~ "thinking"
      assert payload["tooltip"] =~ "3 pending"
      [status | actions] = payload["items"]
      assert status["enabled"] == false
      assert status["label"] =~ "3 pending approvals"

      assert Enum.map(actions, & &1["id"]) ==
               ["show", "new_session", "pause_gateways", "open_data_folder", "quit"]

      assert Enum.find(actions, &(&1["id"] == "pause_gateways"))["label"] == "Pause gateways"

      :ok =
        Desktop.Tauri.tray_update(%{
          status: :idle,
          thinking: 0,
          pending: 0,
          gateways_paused: true
        })

      assert %{"payload" => %{"items" => items}} = read_line!(shell)
      assert Enum.find(items, &(&1["id"] == "pause_gateways"))["label"] == "Resume gateways"
    end

    test "open_dialog is a request, answered by an event carrying its id, once the shell has said hello",
         %{path: path} do
      socket = connect!(path)
      name = :"dialog-shell-#{System.unique_integer([:positive])}"
      start_supervised!({Desktop.Shell, impl: Desktop.Tauri, name: name, token: "t0ken"})
      # A call returns only after the server's start-up continuation, which is where it subscribes
      # to the channel; an event sent before that would reach no subscriber.
      _ = Desktop.Shell.status(name)
      send_event!(socket, "hello", %{token: "t0ken"})
      wait_until(fn -> Desktop.Shell.status(name).trusted end)

      task =
        Task.async(fn -> Desktop.Tauri.open_dialog(kind: :folder, title: "Pick", shell: name) end)

      %{"payload" => %{"id" => id} = payload} = read_until!(socket, "open_dialog")
      assert payload["kind"] == "folder" and payload["title"] == "Pick"

      send_event!(socket, "dialog_result", %{id: id, paths: ["/home/me/projects"]})
      assert {:ok, ["/home/me/projects"]} = Task.await(task)

      # Cancelled: no paths, which is an answer, not an error.
      task = Task.async(fn -> Desktop.Tauri.open_dialog(kind: :folder, shell: name) end)
      %{"payload" => %{"id" => id}} = read_until!(socket, "open_dialog")
      send_event!(socket, "dialog_result", %{id: id, paths: []})
      assert {:ok, []} = Task.await(task)
    end

    test "a peer that has not presented the shell's token is not believed (finding F2)", %{
      path: path
    } do
      socket = connect!(path)
      name = :"dialog-shell-#{System.unique_integer([:positive])}"
      start_supervised!({Desktop.Shell, impl: Desktop.Tauri, name: name, token: "t0ken"})
      _ = Desktop.Shell.status(name)
      send_event!(socket, "hello", %{token: "wrong"})
      # The wrong hello's warning is the sign it arrived; then ask.
      Process.sleep(100)

      assert {:error, :untrusted_channel} =
               Desktop.Tauri.open_dialog(kind: :folder, shell: name, timeout: 500)

      refute Desktop.Shell.status(name).trusted
    end
  end

  defp send_event!(socket, name, payload) do
    line = JSON.encode!(%{type: "event", name: name, payload: payload}) <> "\n"
    :ok = :gen_tcp.send(socket, line)
  end

  defp read_until!(socket, name, tries \\ 20) do
    case read_line!(socket) do
      %{"name" => ^name} = line -> line
      _other when tries > 0 -> read_until!(socket, name, tries - 1)
      other -> flunk("no #{name} line; last was #{inspect(other)}")
    end
  end

  defp connect!(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line], 2_000)

    # One byte counts as a heartbeat and as the frontend having attached; the manager records
    # the socket for outbound commands when it accepts, which is asynchronous to this connect.
    :ok = :gen_tcp.send(socket, ~s({"type":"heartbeat"}\n))
    wait_until(fn -> :sys.get_state(ExTauri.ShutdownManager).client_socket != nil end)
    socket
  end

  defp read_line!(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    {:ok, decoded} = JSON.decode(line)
    decoded
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
