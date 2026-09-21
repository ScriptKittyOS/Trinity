# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.MemoryLive do
  @moduledoc """
  `/memory` (slice 030): a persona's always-on tiers (`profile`, `always_on`) over every
  scope, each entry editable in place and deletable, an add form, the budget, and the
  consolidation proposals waiting for a decision. Every write is `Trinity.Memory.AlwaysOn`'s
  with `by: "ui"`, so it is in the change log like the tool's; a proposal is applied or
  rejected through `Trinity.Memory.Consolidator`. Running sessions keep their snapshot until
  their next start or refresh.

  `/memory?tab=semantic` (slice 032): the semantic tier. The tier's status line (on, or why
  it is unavailable), the model download as an explicit action with progress when the local
  model is missing, a search box over `Trinity.Memory.Retriever` (fused hits with their
  scores and which list found them), and every semantic memory with its provenance link to
  the message it came from, deletable or pinnable (pin: promoted to `always_on`, logged).
  """
  use TrinityWeb, :live_view

  alias Trinity.Memory.{AlwaysOn, Budget, Consolidator, Embedders, Retriever, Semantic}
  alias Trinity.Personas

  @tabs ~w(always_on semantic)
  @model_bytes 91_359_935

  @impl true
  def mount(params, _session, socket) do
    personas = Personas.list()
    persona = Enum.find(personas, &(&1.id == params["persona_id"])) || Personas.default()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Memory"),
       personas: personas,
       persona: persona,
       editing: nil,
       tab: "always_on",
       query: "",
       hits: nil,
       download: nil
     )}
  end

  # The tab is the URL's; every patch reloads, so a tab shows what the other's writes left.
  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "always_on"
    {:noreply, socket |> assign(tab: tab) |> load()}
  end

  defp load(%{assigns: %{persona: persona}} = socket) do
    assign(socket,
      entries: AlwaysOn.all(persona.id),
      budget: Budget.status(persona.id),
      proposals: Consolidator.pending(persona.id),
      changes: AlwaysOn.changes(persona.id, limit: 20),
      semantic: Semantic.all(persona.id),
      semantic_count: Semantic.count(persona.id),
      status: Semantic.status()
    )
  end

  @impl true
  def handle_event("pick_persona", %{"persona_id" => id}, socket) do
    persona = Enum.find(socket.assigns.personas, &(&1.id == id)) || socket.assigns.persona
    {:noreply, socket |> assign(persona: persona, editing: nil, hits: nil) |> load()}
  end

  def handle_event(
        "semantic_search",
        %{"query" => query},
        %{assigns: %{persona: persona}} = socket
      ) do
    query = String.trim(query)

    hits =
      if query == "",
        do: nil,
        else:
          Retriever.relevant(persona.id, nil, query, k: 20, touch: false) |> Enum.map(&decorate/1)

    {:noreply, assign(socket, query: query, hits: hits)}
  end

  def handle_event("semantic_delete", %{"id" => id}, socket) do
    with %{} = entry <- Enum.find(socket.assigns.semantic, &(&1.id == id)),
         {:ok, _} <- Semantic.remove(entry, by: "ui") do
      {:noreply, socket |> assign(hits: nil) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not deleted."))}
    end
  end

  def handle_event("semantic_pin", %{"id" => id}, socket) do
    with %{} = entry <- Enum.find(socket.assigns.semantic, &(&1.id == id)),
         {:ok, _} <- Semantic.pin(entry, by: "ui") do
      {:noreply, socket |> assign(hits: nil) |> load()}
    else
      {:error, :exists} ->
        {:noreply, put_flash(socket, :error, gettext("That key is already always in mind."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not pinned."))}
    end
  end

  # The one network egress on this page, started by a click and nothing else: the weights
  # and tokenizer into the model cache, under the memory task supervisor; the page ticks the
  # cache's size against the model's while it runs.
  def handle_event("download_model", _params, %{assigns: %{download: nil}} = socket) do
    me = self()

    {:ok, _} =
      Task.Supervisor.start_child(Trinity.Memory.TaskSupervisor, fn ->
        send(me, {:download_done, Embedders.Bumblebee.download()})
      end)

    Process.send_after(self(), :download_tick, 1_000)
    {:noreply, assign(socket, download: %{bytes: cache_bytes(), of: @model_bytes})}
  end

  def handle_event("download_model", _params, socket), do: {:noreply, socket}

  def handle_event(
        "add",
        %{"tier" => tier, "key" => key, "body" => body},
        %{assigns: %{persona: persona}} = socket
      ) do
    attrs = %{
      persona_id: persona.id,
      tier: tier,
      scope: AlwaysOn.persona_scope(persona.id),
      key: String.trim(key),
      body: String.trim(body)
    }

    case AlwaysOn.add(attrs, by: "ui") do
      {:ok, _} ->
        {:noreply, load(socket)}

      {:error, :exists} ->
        {:noreply, put_flash(socket, :error, gettext("That key exists in this tier."))}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, gettext("Not added: %{e}", e: inspect(cs.errors)))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket), do: {:noreply, assign(socket, editing: id)}
  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save", %{"entry_id" => id, "body" => body}, socket) do
    with %{} = entry <- Enum.find(socket.assigns.entries, &(&1.id == id)),
         {:ok, _} <- AlwaysOn.replace(entry, String.trim(body), by: "ui") do
      {:noreply, socket |> assign(editing: nil) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not saved."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %{} = entry <- Enum.find(socket.assigns.entries, &(&1.id == id)),
         {:ok, _} <- AlwaysOn.remove(entry, by: "ui") do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not deleted."))}
    end
  end

  def handle_event("apply_proposal", %{"id" => id}, socket) do
    with %{} = proposal <- Consolidator.get(id),
         {:ok, _} <- Consolidator.apply_proposal(proposal, by: "ui") do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not applied."))}
    end
  end

  def handle_event("reject_proposal", %{"id" => id}, socket) do
    with %{} = proposal <- Consolidator.get(id),
         {:ok, _} <- Consolidator.reject_proposal(proposal) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not rejected."))}
    end
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:download_tick, %{assigns: %{download: %{} = d}} = socket) do
    Process.send_after(self(), :download_tick, 1_000)
    {:noreply, assign(socket, download: %{d | bytes: cache_bytes()})}
  end

  def handle_info(:download_tick, socket), do: {:noreply, socket}

  def handle_info({:download_done, :ok}, socket) do
    {:noreply,
     socket
     |> assign(download: nil)
     |> put_flash(:info, gettext("The model is downloaded; semantic recall is on."))
     |> load()}
  end

  def handle_info({:download_done, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(download: nil)
     |> put_flash(:error, gettext("The download failed: %{r}", r: inspect(reason)))
     |> load()}
  end

  defp cache_bytes do
    dir = Embedders.Bumblebee.cache_dir()

    if File.dir?(dir) do
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reduce(0, &(file_size(&1) + &2))
    else
      0
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} -> size
      _ -> 0
    end
  end

  # A hit with what the page shows: the memory's source message's session, for the link.
  defp decorate(%{kind: :memory, ref: %{source_message_id: mid}} = hit) when is_binary(mid) do
    case Trinity.Sessions.get_message(mid) do
      %{session_id: sid} -> Map.put(hit, :source_session_id, sid)
      _ -> hit
    end
  end

  defp decorate(hit), do: hit

  defp source_session(%{source_message_id: nil}), do: nil

  defp source_session(%{source_message_id: mid}) do
    case Trinity.Sessions.get_message(mid) do
      %{session_id: sid} -> sid
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Memory")}</span>
        <form id="memory-persona" phx-change="pick_persona" class="contents">
          <select
            name="persona_id"
            class="rounded-field border border-base-300 bg-base-100 px-2 py-1 text-meta"
          >
            <option :for={p <- @personas} value={p.id} selected={p.id == @persona.id}>
              {p.name}
            </option>
          </select>
        </form>
        <span
          id="budget"
          class={[
            "rounded-pill px-2 py-0.5 font-mono text-meta",
            @budget.over? && "bg-error/20 text-error",
            !@budget.over? && "bg-base-300"
          ]}
        >
          {@budget.used} / {@budget.budget} {gettext("bytes")}
        </span>
      </:bar>
      <div
        id="memory"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-4xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <nav id="memory-tabs" class="flex gap-2 border-b border-base-300 pb-2">
          <.link
            patch={~p"/memory?persona_id=#{@persona.id}&tab=always_on"}
            class={[
              "btn btn-sm",
              @tab == "always_on" && "btn-primary",
              @tab != "always_on" && "btn-ghost"
            ]}
          >
            {gettext("Always on")}
          </.link>
          <.link
            id="tab-semantic"
            patch={~p"/memory?persona_id=#{@persona.id}&tab=semantic"}
            class={[
              "btn btn-sm",
              @tab == "semantic" && "btn-primary",
              @tab != "semantic" && "btn-ghost"
            ]}
          >
            {gettext("Semantic")} <span class="font-mono opacity-70">{@semantic_count}</span>
          </.link>
        </nav>

        <section :if={@tab == "semantic"} id="semantic" class="flex flex-col gap-4">
          <p
            id="semantic-status"
            class={[
              "rounded-field px-3 py-2 text-ui",
              @status == :on && "bg-success/10",
              @status != :on && "bg-warning/10"
            ]}
          >
            {Semantic.describe(@status)}
            <span :if={@status != :on}>{gettext("Full-text search still works.")}</span>
          </p>
          <div
            :if={@status == {:off, :model_missing}}
            id="model-download"
            class="flex items-center gap-3"
          >
            <button
              :if={@download == nil}
              phx-click="download_model"
              data-confirm={
                gettext(
                  "Download the embedding model (91 MB) from huggingface.co into the data directory? This is the only network access this page makes."
                )
              }
              class="btn btn-sm btn-primary"
            >
              {gettext("Download the model")}
            </button>
            <span :if={@download} class="font-mono text-meta">
              {gettext("downloading: %{got} of %{of} MB",
                got: div(@download.bytes, 1_000_000),
                of: div(@download.of, 1_000_000)
              )}
            </span>
            <progress :if={@download} class="progress w-48" value={@download.bytes} max={@download.of}></progress>
          </div>

          <form id="semantic-search" phx-submit="semantic_search" class="flex items-center gap-2">
            <input
              name="query"
              value={@query}
              placeholder={gettext("recall…")}
              class="flex-1 rounded-field border border-base-300 bg-base-100 px-2 py-2 text-ui"
            />
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Recall")}</button>
          </form>
          <ul :if={@hits != nil} id="semantic-hits" class="flex flex-col gap-1">
            <li :if={@hits == []} class="opacity-70">{gettext("Nothing recalled.")}</li>
            <li
              :for={h <- @hits}
              id={"hit-#{h.kind}-#{h.id}"}
              class="flex items-start gap-2 rounded-field border border-base-300 px-3 py-2 text-ui"
            >
              <span class="font-mono text-meta opacity-70">{Float.round(h.score, 4)}</span>
              <span class="font-mono text-meta opacity-70">{Enum.map_join(
                h.found_by,
                "+",
                &Atom.to_string/1
              )}</span>
              <span class="flex-1">{h.text}</span>
              <.link
                :if={h.kind == :message}
                navigate={~p"/s/#{h.ref.session_id}"}
                class="link text-meta"
              >
                {h.ref.session_title || gettext("untitled")}
              </.link>
              <.link
                :if={h[:source_session_id]}
                navigate={~p"/s/#{h.source_session_id}"}
                class="link text-meta"
              >
                {gettext("source")}
              </.link>
            </li>
          </ul>

          <h2 class="text-lg font-semibold">{gettext("Remembered")}</h2>
          <p :if={@semantic == []} class="opacity-70">
            {gettext("Nothing in the semantic tier yet; the observer adds to it after each turn.")}
          </p>
          <ul class="flex flex-col gap-1">
            <li
              :for={e <- @semantic}
              id={"semantic-#{e.id}"}
              class="flex items-start gap-2 rounded-field border border-base-300 px-3 py-2 text-ui"
            >
              <span class="font-mono text-meta opacity-70" title={e.scope}>{short_scope(e.scope)}</span>
              <span class="font-mono text-meta opacity-70">{Calendar.strftime(
                e.inserted_at,
                "%Y-%m-%d"
              )}</span>
              <span class="flex-1">{e.body}</span>
              <span :if={e.confidence} class="font-mono text-meta opacity-70">{e.confidence}</span>
              <.link
                :if={source_session(e)}
                navigate={~p"/s/#{source_session(e)}"}
                class="link text-meta"
              >
                {gettext("source")}
              </.link>
              <button phx-click="semantic_pin" phx-value-id={e.id} class="btn btn-xs btn-ghost">{gettext(
                "pin"
              )}</button>
              <button
                phx-click="semantic_delete"
                phx-value-id={e.id}
                data-confirm={gettext("Delete this memory?")}
                class="btn btn-xs btn-ghost text-error"
              >{gettext("delete")}</button>
            </li>
          </ul>
        </section>

        <section :if={@tab == "always_on" and @proposals != []} class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Consolidation waiting for you")}</h2>
          <div
            :for={p <- @proposals}
            id={"proposal-#{p.id}"}
            class="flex flex-col gap-2 rounded-field border border-warning/50 px-3 py-2"
          >
            <p class="text-meta opacity-70">
              {gettext("%{before} bytes now, %{after} proposed, budget %{budget}",
                before: p.bytes_before,
                after: p.bytes_after,
                budget: p.budget
              )}
            </p>
            <ul class="font-mono text-meta">
              <li :for={e <- p.entries["entries"] || []}>[{e["tier"]}] {e["key"]}: {e["body"]}</li>
            </ul>
            <div class="flex gap-2">
              <button phx-click="apply_proposal" phx-value-id={p.id} class="btn btn-sm btn-primary">{gettext(
                "Apply"
              )}</button>
              <button phx-click="reject_proposal" phx-value-id={p.id} class="btn btn-sm btn-ghost">{gettext(
                "Reject"
              )}</button>
            </div>
          </div>
        </section>

        <section
          :for={tier <- ["profile", "always_on"]}
          :if={@tab == "always_on"}
          class="flex flex-col gap-2"
        >
          <h2 class="text-lg font-semibold">
            {if tier == "profile", do: gettext("About the person"), else: gettext("Always in mind")}
          </h2>
          <p :if={Enum.filter(@entries, &(&1.tier == tier)) == []} class="opacity-70">
            {gettext("Nothing kept in this tier.")}
          </p>
          <ul class="flex flex-col gap-1">
            <li
              :for={e <- Enum.filter(@entries, &(&1.tier == tier))}
              id={"entry-#{e.id}"}
              class="flex items-start gap-2 rounded-field border border-base-300 px-3 py-2 text-ui"
            >
              <span class="font-mono text-meta opacity-70" title={e.scope}>{short_scope(e.scope)}</span>
              <span class="font-mono font-semibold">{e.key}</span>
              <form
                :if={@editing == e.id}
                id={"edit-#{e.id}"}
                phx-submit="save"
                class="flex flex-1 items-center gap-2"
              >
                <input type="hidden" name="entry_id" value={e.id} />
                <input
                  name="body"
                  value={e.body}
                  class="flex-1 rounded-field border border-base-300 bg-base-100 px-2 py-1"
                />
                <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
                <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-ghost">{gettext(
                  "Cancel"
                )}</button>
              </form>
              <span :if={@editing != e.id} class="flex-1">{e.body}</span>
              <button
                :if={@editing != e.id}
                phx-click="edit"
                phx-value-id={e.id}
                class="btn btn-xs btn-ghost"
              >{gettext("edit")}</button>
              <button
                phx-click="delete"
                phx-value-id={e.id}
                data-confirm={gettext("Delete this entry?")}
                class="btn btn-xs btn-ghost text-error"
              >{gettext("delete")}</button>
            </li>
          </ul>
        </section>

        <form
          :if={@tab == "always_on"}
          id="memory-add"
          phx-submit="add"
          class="flex items-center gap-2"
        >
          <select
            name="tier"
            class="rounded-field border border-base-300 bg-base-100 px-2 py-2 text-meta"
          >
            <option value="always_on">{gettext("always in mind")}</option>
            <option value="profile">{gettext("about the person")}</option>
          </select>
          <input
            name="key"
            placeholder={gettext("key")}
            class="w-40 rounded-field border border-base-300 bg-base-100 px-2 py-2 font-mono text-ui"
          />
          <input
            name="body"
            placeholder={gettext("what to keep")}
            class="flex-1 rounded-field border border-base-300 bg-base-100 px-2 py-2 text-ui"
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Add")}</button>
        </form>

        <section class="flex flex-col gap-1">
          <h2 class="text-ui font-semibold opacity-70">{gettext("Recent changes")}</h2>
          <ul id="changes" class="font-mono text-meta opacity-70">
            <li :for={c <- @changes}>{c.action} {c.tier}/{c.key} {gettext("by")} {c.by}</li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp short_scope("global"), do: "global"
  defp short_scope("persona:" <> _), do: "persona"
  defp short_scope("session:" <> _), do: "session"
  defp short_scope(o), do: o
end
