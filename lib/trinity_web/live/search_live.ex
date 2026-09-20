# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SearchLive do
  @moduledoc """
  `/search` (slice 031): a query box and the ranked hits from `Trinity.Memory.Search`, each
  linking into its session at the message (`/s/:id#message-<id>`, the chat's stream dom id).
  The query lives in the URL (`?q=`), so a search is a link. The page reads; it writes nothing.
  """
  use TrinityWeb, :live_view

  alias Trinity.Memory.Search

  @limit 50

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Search"), q: "", hits: [])}

  @impl true
  def handle_params(params, _uri, socket) do
    q = params |> Map.get("q", "") |> String.trim()
    hits = if q == "", do: [], else: Search.messages(q, limit: @limit)
    {:noreply, assign(socket, q: q, hits: hits)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/search?#{[q: q]}")}

  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Search")}</span>
      </:bar>
      <div
        id="search"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-4xl flex-col gap-4 overflow-y-auto px-4 py-6"
      >
        <form id="search-form" phx-submit="search" class="flex items-center gap-2">
          <input
            id="q"
            type="search"
            name="q"
            value={@q}
            autofocus
            autocomplete="off"
            placeholder={gettext("words to find in every conversation")}
            class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Search")}</button>
        </form>

        <p :if={@q != "" and @hits == []} id="no-hits" class="opacity-70">
          {gettext("Nothing matches %{q}.", q: @q)}
        </p>
        <p :if={@q != "" and @hits != []} class="text-meta opacity-70">
          {gettext("%{n} hits for %{q}", n: length(@hits), q: @q)}
        </p>

        <ol :if={@hits != []} id="hits" class="flex flex-col gap-2">
          <li
            :for={h <- @hits}
            id={"hit-#{h.message_id}"}
            class="rounded-field border border-base-300 px-3 py-2"
          >
            <.link
              navigate={~p"/s/#{h.session_id}" <> "#message-#{h.message_id}"}
              class="flex flex-col gap-1"
            >
              <div class="flex items-center gap-2 text-meta opacity-70">
                <span class="font-semibold">{h.session_title || gettext("Untitled session")}</span>
                <span>·</span>
                <span class="font-mono">{Calendar.strftime(h.inserted_at, "%Y-%m-%d %H:%M")}</span>
                <span>·</span>
                <span>{h.role}</span>
                <span class="font-mono">#{h.seq}</span>
              </div>
              <div class="text-ui"><.snippet text={h.snippet} /></div>
            </.link>
          </li>
        </ol>
      </div>
    </Layouts.app>
    """
  end

  # The snippet's [brackets] mark the matches, rendered as <mark>; everything else is text
  # the template escapes.
  attr :text, :string, required: true

  defp snippet(assigns) do
    pieces =
      assigns.text
      |> String.split(~r/\[|\]/, include_captures: true)
      |> Enum.reduce({[], false}, fn
        "[", {acc, _} -> {acc, true}
        "]", {acc, _} -> {acc, false}
        piece, {acc, marked} -> {[{piece, marked} | acc], marked}
      end)
      |> elem(0)
      |> Enum.reverse()

    assigns = assign(assigns, pieces: pieces)

    ~H"""
    <span :for={{piece, marked} <- @pieces}><mark :if={marked}>{piece}</mark><span :if={!marked}>{piece}</span></span>
    """
  end
end
