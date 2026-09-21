# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SessionLive.Index do
  @moduledoc """
  The sessions index at `/`: every session, most recently active first, and New session. Slice
  013. A new session is a row on the default persona; the chat itself is `SessionLive.Show`.
  """
  use TrinityWeb, :live_view

  import TrinityWeb.ChatComponents, only: [local_time: 1]

  alias Trinity.Sessions

  @impl true
  def mount(_params, _session, socket) do
    default = Trinity.Personas.default()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Sessions"),
       personas: Trinity.Personas.list(),
       persona_id: default.id
     )
     |> stream(:sessions, Sessions.list_sessions(limit: 100))}
  end

  @impl true
  def handle_event("new_session", _params, socket), do: {:noreply, new_session(socket)}
  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  # Slice 030: the persona picker chooses who the next new session belongs to.
  def handle_event("pick_persona", %{"persona_id" => id}, socket),
    do: {:noreply, assign(socket, persona_id: id)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Sessions")}</span>
        <.link id="search-link" navigate={~p"/search"} class="text-meta opacity-70 hover:opacity-100">
          {gettext("search")}
        </.link>
      </:bar>
      <div
        id="index"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-3xl flex-col gap-4 px-4 py-6"
      >
        <div class="flex items-center justify-between">
          <h1 class="text-lg font-semibold">{gettext("Sessions")}</h1>
          <form
            id="persona-picker"
            phx-change="pick_persona"
            class="flex items-center gap-2 text-meta"
          >
            <label class="opacity-70">{gettext("Persona")}</label>
            <select
              name="persona_id"
              class="rounded-field border border-base-300 bg-base-100 px-2 py-1 text-meta"
            >
              <option :for={p <- @personas} value={p.id} selected={p.id == @persona_id}>
                {p.name}
              </option>
            </select>
            <.link navigate={~p"/personas"} class="underline opacity-70">{gettext("edit")}</.link>
            <.link navigate={~p"/memory"} class="underline opacity-70">{gettext("memory")}</.link>
          </form>
          <button
            id="new-session"
            type="button"
            phx-click="new_session"
            class="flex cursor-pointer items-center gap-1.5 rounded-field bg-primary px-3 py-2 text-ui font-semibold text-primary-content transition hover:brightness-110"
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New session")}
            <kbd class="ml-1 rounded-pill bg-primary-content/20 px-1.5 font-mono text-meta">⌘K</kbd>
          </button>
        </div>
        <div id="sessions" phx-update="stream" class="flex flex-col gap-2">
          <p
            id="sessions-empty"
            class="hidden only:block rounded-panel border border-dashed border-base-300 p-8 text-center opacity-70"
          >
            {gettext("No sessions yet. Start one with New session or Ctrl/Cmd+K.")}
          </p>
          <.link
            :for={{dom_id, session} <- @streams.sessions}
            id={dom_id}
            navigate={~p"/s/#{session.id}"}
            class="flex items-center gap-3 rounded-panel border border-base-300 bg-base-100 px-4 py-3 transition hover:border-primary"
          >
            <.icon name="hero-chat-bubble-left-right-micro" class="size-5 opacity-60" />
            <span class="min-w-0 flex-1 truncate text-ui">{session.title ||
              gettext("Untitled session")}</span>
            <span class="font-mono text-meta opacity-60">{session.model || gettext("default model")}</span>
            <span class="text-meta opacity-60">
              <.local_time
                id={dom_id <> "-time"}
                at={session.last_activity_at || session.inserted_at}
                format="datetime"
              />
            </span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  @spec new_session(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def new_session(socket) do
    persona_id = Map.get(socket.assigns, :persona_id) || Sessions.default_persona().id

    case Sessions.create_session(%{persona_id: persona_id, origin: "desktop"}) do
      {:ok, session} -> push_navigate(socket, to: ~p"/s/#{session.id}")
      {:error, _} -> put_flash(socket, :error, gettext("The session could not be created."))
    end
  end
end
