# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop.Noop do
  @moduledoc """
  No desktop shell (slice 100, AC10): headless, CI and plain `mix phx.server`. Every call answers
  `{:error, :no_shell}` rather than `:ok`, so nothing above can mistake "there is no window" for
  "the window did it".
  """
  @behaviour Trinity.Desktop

  @impl true
  def available?, do: false

  @impl true
  def notify(_title, _opts), do: {:error, :no_shell}

  @impl true
  def tray_update(_status), do: {:error, :no_shell}

  @impl true
  def open_dialog(_opts), do: {:error, :no_shell}

  @impl true
  def show_window, do: {:error, :no_shell}

  @impl true
  def focus_path(_path), do: {:error, :no_shell}

  @impl true
  def open_path(_path), do: {:error, :no_shell}

  @impl true
  def set_hotkey(_accelerator), do: {:error, :no_shell}

  @impl true
  def set_autostart(_enabled), do: {:error, :no_shell}

  @impl true
  def quit, do: {:error, :no_shell}
end
