# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop do
  @moduledoc """
  The seam between Trinity and the window it is shown in (slice 100; ADR-0004's consequence "all
  desktop OS integration goes through `Trinity.Desktop`").

  Two implementations ship:

    * `Trinity.Desktop.Tauri`: commands to the Tauri shell over the channel `ex_tauri` keeps
      between the Rust window and this BEAM (the heartbeat's socket), and events back.
    * `Trinity.Desktop.Noop`: no shell. Every call answers `{:error, :no_shell}`, so a caller can
      tell "there is no window" from "the window said no". Headless, CI and plain
      `mix phx.server` run on it (AC10).

  The implementation is chosen from the process's environment unless configuration pins one
  (`config :trinity, :desktop, impl:`; the suite pins `Noop`): `Tauri` when the shell launched
  this process, which it says by setting `TRINITY_SHELL_TOKEN`, and `Noop` otherwise and always
  under `TRINITY_MODE=headless`.

  `Trinity.Desktop.Shell` is the process that uses this seam on Trinity's behalf: the tray, the
  notifications, the tray's actions. Other callers (the Settings page) call the functions below.

  ## The callbacks

  The five the slice names (`notify/2`, `tray_update/1`, `open_dialog/1`, `show_window/0`,
  `quit/0`), and five the slice's scope needs: `focus_path/1` (show the window on a page, for a
  notification's click and New session), `open_path/1` (Open data folder), `set_hotkey/1`,
  `set_autostart/1`, and `available?/0`.
  """
  use Boundary,
    deps: [Trinity, Trinity.Gateways],
    exports: [Noop, Tauri, Shell]

  @typedoc "What the tray shows (see `Trinity.Desktop.Tauri.tray_spec/1` for the menu it becomes)."
  @type tray_status :: %{
          required(:status) => :idle | :thinking,
          required(:pending) => non_neg_integer(),
          optional(:thinking) => non_neg_integer(),
          optional(:gateways_paused) => boolean()
        }

  @typedoc "`:kind` (`:folder` is the one used), `:title`; implementations may take more."
  @type dialog_opts :: keyword()

  @doc "Whether a shell is attached and listening."
  @callback available?() :: boolean()

  @doc "An OS notification. Options: `:body`, `:path` (where a click takes the window)."
  @callback notify(title :: String.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc "Replaces the tray's status and menu."
  @callback tray_update(tray_status()) :: :ok | {:error, term()}

  @doc "A native file or folder dialog; the paths chosen, `[]` when cancelled."
  @callback open_dialog(dialog_opts()) :: {:ok, [Path.t()]} | {:error, term()}

  @doc "Shows the window and gives it focus."
  @callback show_window() :: :ok | {:error, term()}

  @doc "Shows the window on a page of this app (a path such as `/s/<id>#approval-<id>`)."
  @callback focus_path(String.t()) :: :ok | {:error, term()}

  @doc "Opens a directory in the OS file manager."
  @callback open_path(Path.t()) :: :ok | {:error, term()}

  @doc "Registers the global show/hide shortcut (an accelerator such as `CommandOrControl+Shift+Space`); `nil` removes it."
  @callback set_hotkey(String.t() | nil) :: :ok | {:error, term()}

  @doc "Turns launch-at-login on or off."
  @callback set_autostart(boolean()) :: :ok | {:error, term()}

  @doc "Quits the app: the shell stops this BEAM the graceful way and exits."
  @callback quit() :: :ok | {:error, term()}

  @doc "The implementation in force."
  @spec impl() :: module()
  def impl do
    Application.get_env(:trinity, :desktop, [])[:impl] || impl_for(System.get_env())
  end

  @doc """
  The implementation a process with environment `env` selects: `Tauri` when the shell launched
  it (a non-empty `TRINITY_SHELL_TOKEN`) and it is not headless, else `Noop`.
  """
  @spec impl_for(%{optional(String.t()) => String.t()}) :: module()
  def impl_for(env) when is_map(env) do
    shell? = Map.get(env, "TRINITY_SHELL_TOKEN", "") != ""
    headless? = Map.get(env, "TRINITY_MODE") == "headless"
    if shell? and not headless?, do: __MODULE__.Tauri, else: __MODULE__.Noop
  end

  @doc "See the callback."
  @spec available?() :: boolean()
  def available?, do: impl().available?()

  @doc "See the callback."
  @spec notify(String.t(), keyword()) :: :ok | {:error, term()}
  def notify(title, opts \\ []), do: impl().notify(title, opts)

  @doc "See the callback."
  @spec tray_update(tray_status()) :: :ok | {:error, term()}
  def tray_update(status), do: impl().tray_update(status)

  @doc "See the callback."
  @spec open_dialog(dialog_opts()) :: {:ok, [Path.t()]} | {:error, term()}
  def open_dialog(opts \\ []), do: impl().open_dialog(opts)

  @doc "See the callback."
  @spec show_window() :: :ok | {:error, term()}
  def show_window, do: impl().show_window()

  @doc "See the callback."
  @spec focus_path(String.t()) :: :ok | {:error, term()}
  def focus_path(path), do: impl().focus_path(path)

  @doc "See the callback."
  @spec open_path(Path.t()) :: :ok | {:error, term()}
  def open_path(path), do: impl().open_path(path)

  @doc "See the callback."
  @spec set_hotkey(String.t() | nil) :: :ok | {:error, term()}
  def set_hotkey(accelerator), do: impl().set_hotkey(accelerator)

  @doc "See the callback."
  @spec set_autostart(boolean()) :: :ok | {:error, term()}
  def set_autostart(enabled), do: impl().set_autostart(enabled)

  @doc "See the callback."
  @spec quit() :: :ok | {:error, term()}
  def quit, do: impl().quit()

  @doc """
  Whether `accelerator` reads as a shortcut the shell's parser accepts: one or more modifiers and
  one key, joined by `+`. Checked before it is saved, so a typo is refused on the page rather than
  silently ignored by the shell.
  """
  @spec valid_hotkey?(term()) :: boolean()
  def valid_hotkey?(accelerator) when is_binary(accelerator) do
    modifiers =
      ~w(CommandOrControl CmdOrCtrl Command Cmd Control Ctrl Alt Option AltGr Shift Super Meta)

    case String.split(accelerator, "+") do
      [_only] ->
        false

      parts ->
        {mods, [key]} = Enum.split(parts, -1)

        Enum.all?(mods, &(&1 in modifiers)) and
          Regex.match?(~r/\A([A-Z0-9]|F([1-9]|1[0-9]|2[0-4])|Space|Enter|Tab|Escape)\z/, key)
    end
  end

  def valid_hotkey?(_), do: false
end
