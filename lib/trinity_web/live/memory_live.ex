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
  """
  use TrinityWeb, :live_view

  alias Trinity.Memory.{AlwaysOn, Budget, Consolidator}
  alias Trinity.Personas

  @impl true
  def mount(params, _session, socket) do
    personas = Personas.list()
    persona = Enum.find(personas, &(&1.id == params["persona_id"])) || Personas.default()

    {:ok,
     socket
     |> assign(page_title: gettext("Memory"), personas: personas, persona: persona, editing: nil)
     |> load()}
  end

  defp load(%{assigns: %{persona: persona}} = socket) do
    assign(socket,
      entries: AlwaysOn.all(persona.id),
      budget: Budget.status(persona.id),
      proposals: Consolidator.pending(persona.id),
      changes: AlwaysOn.changes(persona.id, limit: 20)
    )
  end

  @impl true
  def handle_event("pick_persona", %{"persona_id" => id}, socket) do
    persona = Enum.find(socket.assigns.personas, &(&1.id == id)) || socket.assigns.persona
    {:noreply, socket |> assign(persona: persona, editing: nil) |> load()}
  end

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
        <section :if={@proposals != []} class="flex flex-col gap-2">
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

        <section :for={tier <- ["profile", "always_on"]} class="flex flex-col gap-2">
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

        <form id="memory-add" phx-submit="add" class="flex items-center gap-2">
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
