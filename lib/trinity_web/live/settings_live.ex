# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SettingsLive do
  @moduledoc """
  `/settings` (slice 034, the first settings page): the export as a download, with and without
  the private keys, the restore procedure in a sentence with a link to docs/backup.md, and
  links to the boot receipt, the personas and the memory.
  """
  use TrinityWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    layout = Trinity.Archive.Layout.current()

    {:ok,
     assign(socket,
       page_title: gettext("Settings"),
       data_dir: layout.data_dir,
       present: Trinity.Archive.Layout.present(layout)
     )}
  end

  @impl true
  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

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
