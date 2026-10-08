# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SettingsLive do
  @moduledoc """
  `/settings`. Slice 034 made it: the export as a download, with and without the private keys,
  and links to the boot receipt, the personas and the memory. Slice 100 adds the desktop's
  settings: provider keys (stored in the OS keychain and only there, AC5), the folders the
  filesystem tools may use (picked in the native dialog, or typed), the global shortcut,
  notifications, launch at login, pausing the gateways, and the data directory and the budgets in
  force, shown. Budgets and the data directory are set outside the app (configuration and the
  environment); the page says where.
  """
  use TrinityWeb, :live_view

  import TrinityWeb.SettingsComponents

  alias Trinity.{Desktop, Gateways, Settings}
  alias TrinityWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    layout = Trinity.Archive.Layout.current()
    settings = Settings.all()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Settings"),
       data_dir: layout.data_dir,
       present: Trinity.Archive.Layout.present(layout),
       hotkey: settings.hotkey,
       hotkey_error: nil,
       muted: settings.notifications_muted,
       autostart: settings.autostart,
       paused: Gateways.paused?(),
       budgets:
         Enum.map(Trinity.Telemetry.Costs.scopes(), &{&1, Trinity.Telemetry.Costs.budget(&1)})
     )
     |> SettingsComponents.assign_keys()
     |> SettingsComponents.assign_roots()}
  end

  @impl true
  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  def handle_event("save_key", %{"name" => name, "secret" => %{"value" => value}}, socket),
    do: {:noreply, SettingsComponents.save_key(socket, name, value)}

  def handle_event("remove_key", %{"name" => name}, socket),
    do: {:noreply, SettingsComponents.remove_key(socket, name)}

  def handle_event("add_root", %{"root" => root}, socket),
    do: {:noreply, SettingsComponents.add_root(socket, root)}

  def handle_event("remove_root", %{"root" => root}, socket),
    do: {:noreply, SettingsComponents.remove_root(socket, root)}

  def handle_event("pick_root", _params, socket),
    do: {:noreply, SettingsComponents.pick_root(socket)}

  def handle_event("save_hotkey", %{"hotkey" => hotkey}, socket) do
    hotkey = String.trim(hotkey)

    if Desktop.valid_hotkey?(hotkey) do
      :ok = Settings.put(:hotkey, hotkey)
      _ = Desktop.set_hotkey(hotkey)
      {:noreply, assign(socket, hotkey: hotkey, hotkey_error: nil)}
    else
      {:noreply,
       assign(socket,
         hotkey_error:
           gettext("%{hotkey} is not a shortcut: modifiers and one key, such as %{example}.",
             hotkey: hotkey,
             example: "CommandOrControl+Shift+Space"
           )
       )}
    end
  end

  def handle_event("toggle_muted", _params, socket) do
    muted = not socket.assigns.muted
    :ok = Settings.put(:notifications_muted, muted)
    {:noreply, assign(socket, muted: muted)}
  end

  def handle_event("toggle_autostart", _params, socket) do
    autostart = not socket.assigns.autostart
    :ok = Settings.put(:autostart, autostart)
    _ = Desktop.set_autostart(autostart)
    {:noreply, assign(socket, autostart: autostart)}
  end

  def handle_event("toggle_gateways", _params, socket) do
    if Gateways.paused?(), do: Gateways.resume(), else: Gateways.pause()
    {:noreply, assign(socket, paused: Gateways.paused?())}
  end

  @impl true
  def handle_async(:pick_root, result, socket),
    do: {:noreply, SettingsComponents.picked(socket, result)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar><span class="opacity-70">{gettext("Settings")}</span></:bar>
      <div
        id="settings"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-3xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <section id="provider-keys" class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Provider keys")}</h2>
          <p class="text-ui opacity-80">
            {gettext(
              "Keys are kept in your operating system's keychain, never in Trinity's database or files. A key in the keychain wins over the same name in the environment."
            )}
          </p>
          <p :if={!@keychain?} class="text-meta text-warning">
            {gettext(
              "No keychain in this run (Trinity was not started by its desktop app). Set a key in the environment instead, under the name shown."
            )}
          </p>
          <.key_row :for={key <- @keys} key={key} keychain?={@keychain?} />
        </section>

        <section id="fs-roots" class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Folders the tools may use")}</h2>
          <p class="text-ui opacity-80">
            {gettext(
              "The file tools read and write inside these folders and the data directory without asking; anywhere else, they ask first."
            )}
          </p>
          <.roots roots={@roots} root_error={@root_error} />
        </section>

        <section id="desktop" class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{gettext("Desktop")}</h2>
          <form id="hotkey-form" phx-submit="save_hotkey" class="flex items-center gap-2">
            <label for="hotkey" class="w-56 text-ui">{gettext("Show or hide Trinity")}</label>
            <input
              id="hotkey"
              type="text"
              name="hotkey"
              value={@hotkey}
              class="input input-sm w-72 font-mono"
            />
            <button type="submit" class="btn btn-sm">{gettext("Save")}</button>
          </form>
          <p :if={@hotkey_error} class="text-meta text-error">{@hotkey_error}</p>
          <label class="flex items-center gap-2 text-ui">
            <input
              id="notifications-muted"
              type="checkbox"
              class="toggle toggle-sm"
              checked={@muted}
              phx-click="toggle_muted"
            />
            {gettext("Mute notifications")}
          </label>
          <label class="flex items-center gap-2 text-ui">
            <input
              id="autostart"
              type="checkbox"
              class="toggle toggle-sm"
              checked={@autostart}
              phx-click="toggle_autostart"
            />
            {gettext("Start Trinity when I log in")}
          </label>
        </section>

        <section id="gateways" class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Gateways")}</h2>
          <div class="flex items-center gap-3 text-ui">
            <span>
              {if @paused,
                do: gettext("Gateways are paused: messages from channels are not read."),
                else: gettext("Gateways are running.")}
            </span>
            <button id="gateways-pause" type="button" phx-click="toggle_gateways" class="btn btn-sm">
              {if @paused, do: gettext("Resume"), else: gettext("Pause")}
            </button>
            <.link navigate={~p"/gateways"} class="underline opacity-70">{gettext("channels")}</.link>
          </div>
        </section>

        <section id="budgets" class="flex flex-col gap-1">
          <h2 class="text-lg font-semibold">{gettext("Budgets")}</h2>
          <dl class="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-1 font-mono text-meta">
            <%= for {scope, limit} <- @budgets do %>
              <dt class="opacity-70">{scope}</dt>
              <dd>{if limit, do: "$#{limit}", else: gettext("none")}</dd>
            <% end %>
          </dl>
          <p class="text-meta opacity-70">
            {gettext(
              "Set in configuration (config :trinity, :budgets); spending is on the activity page."
            )}
          </p>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Take your Trinity with you")}</h2>
          <p class="text-ui opacity-80">
            {gettext(
              "One archive with the databases, the memory, the receipts and the key registry. The private signing key stays out unless you ask for it."
            )}
          </p>
          <div class="flex items-center gap-2">
            <a id="export" href={~p"/settings/export.tar.gz"} class="btn btn-sm btn-primary">{gettext(
              "Export"
            )}</a>
            <a
              id="export-with-keys"
              href={~p"/settings/export.tar.gz?keys=1"}
              class="btn btn-sm btn-ghost"
            >{gettext("Export with the private key")}</a>
          </div>
          <p class="text-meta opacity-70">
            {gettext(
              "Restore on a fresh install with mix trinity.import <archive>; the procedure is in docs/backup.md."
            )}
          </p>
          <dl class="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-1 font-mono text-meta">
            <dt class="opacity-70">{gettext("data directory")}</dt>
            <dd class="break-all">{@data_dir}</dd>
            <dt class="opacity-70">{gettext("present")}</dt>
            <dd class="break-all">{Enum.join(@present, ", ")}</dd>
          </dl>
          <p class="text-meta opacity-70">
            {gettext(
              "The data directory follows the operating system's convention (XDG_DATA_HOME on Linux, APPDATA on Windows, Application Support on macOS); change it there."
            )}
          </p>
        </section>
        <section class="flex flex-col gap-1 text-meta">
          <h2 class="text-ui font-semibold">{gettext("Elsewhere")}</h2>
          <.link navigate={~p"/receipts/boot"} class="underline opacity-70">{gettext(
            "this run's boot receipt"
          )}</.link>
          <.link navigate={~p"/personas"} class="underline opacity-70">{gettext("personas")}</.link>
          <.link navigate={~p"/memory"} class="underline opacity-70">{gettext("memory")}</.link>
          <.link navigate={~p"/permissions"} class="underline opacity-70">{gettext("permissions")}</.link>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
