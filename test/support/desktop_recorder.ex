# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop.Recorder do
  @moduledoc """
  Slice 100. A `Trinity.Desktop` implementation for the suite: every call is sent to the process
  named in `config :trinity, :desktop_recorder` as `{:desktop, call, args}` and answers `:ok`
  (`open_dialog/1` answers the paths in `:desktop_recorder_dialog`, default none).
  """
  @behaviour Trinity.Desktop

  @impl true
  def available?, do: true

  @impl true
  def notify(title, opts), do: record(:notify, [title, opts])

  @impl true
  def tray_update(status), do: record(:tray_update, [status])

  @impl true
  def open_dialog(opts) do
    record(:open_dialog, [opts])
    {:ok, Application.get_env(:trinity, :desktop_recorder_dialog, [])}
  end

  @impl true
  def show_window, do: record(:show_window, [])

  @impl true
  def focus_path(path), do: record(:focus_path, [path])

  @impl true
  def open_path(path), do: record(:open_path, [path])

  @impl true
  def set_hotkey(accelerator), do: record(:set_hotkey, [accelerator])

  @impl true
  def set_autostart(enabled), do: record(:set_autostart, [enabled])

  @impl true
  def quit, do: record(:quit, [])

  defp record(call, args) do
    case Application.get_env(:trinity, :desktop_recorder) do
      pid when is_pid(pid) -> send(pid, {:desktop, call, args})
      _ -> :ok
    end

    :ok
  end
end
