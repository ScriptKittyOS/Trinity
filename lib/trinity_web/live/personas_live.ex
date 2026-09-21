# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.PersonasLive do
  @moduledoc """
  `/personas` and `/personas/:id` (slice 030): the list with a create form, and the editor:
  the SOUL as markdown, the default model, and the quick settings (the `memory` tool's
  rule). Everything here is `Trinity.Personas.create/1` or `update/2`. A change to the soul
  takes effect in the next session; running sessions keep the prompt they started with.
  """
  use TrinityWeb, :live_view

  alias Trinity.Personas

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Personas"), models: Trinity.LLM.models())}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Personas.get(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No such persona."))
         |> push_navigate(to: ~p"/personas")}

      persona ->
        {:noreply, assign(socket, persona: persona, personas: nil, saved: false)}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, persona: nil, personas: Personas.list(), saved: false)}

  @impl true
  def handle_event("save", %{"persona" => attrs}, %{assigns: %{persona: persona}} = socket) do
    attrs = %{soul: attrs["soul"], model: blank_to_nil(attrs["model"])}

    case Personas.update(persona, attrs) do
      {:ok, updated} ->
        {:noreply, assign(socket, persona: updated, saved: true)}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, gettext("Not saved: %{e}", e: inspect(cs.errors)))}
    end
  end

  def handle_event("memory_rule", %{"rule" => rule}, %{assigns: %{persona: persona}} = socket)
      when rule in ["allow", "ask", "deny"] do
    {:ok, updated} = Personas.put_setting(persona, ["permissions", "memory"], rule)
    {:noreply, assign(socket, persona: updated, saved: true)}
  end

  def handle_event("create", %{"name" => name}, socket) do
    case Personas.create(%{
           name: String.trim(name),
           soul: Personas.default().soul,
           settings: %{"permissions" => %{"memory" => "allow"}}
         }) do
      {:ok, persona} ->
        {:noreply, push_patch(socket, to: ~p"/personas/#{persona.id}")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, gettext("Not created: %{e}", e: inspect(cs.errors)))}
    end
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(%{persona: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar><span class="opacity-70">{gettext("Personas")}</span></:bar>
      <div
        id="personas"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-3xl flex-col gap-4 overflow-y-auto px-4 py-6"
      >
        <ul id="persona-list" class="flex flex-col gap-2">
          <li
            :for={p <- @personas}
            id={"persona-#{p.id}"}
            class="flex items-center justify-between rounded-field border border-base-300 px-3 py-2"
          >
            <.link patch={~p"/personas/#{p.id}"} class="font-semibold">{p.name}</.link>
            <span class="font-mono text-meta opacity-70">{p.model || gettext("default model")}</span>
          </li>
        </ul>
        <form id="persona-create" phx-submit="create" class="flex items-center gap-2">
          <input
            name="name"
            placeholder={gettext("a new persona's name")}
            class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Persona")}</span>
        <span class="font-semibold">{@persona.name}</span>
        <.link navigate={~p"/personas"} class="text-meta underline opacity-70">{gettext(
          "all personas"
        )}</.link>
        <span
          :if={@saved}
          id="saved"
          class="rounded-pill bg-success/20 px-2 py-0.5 text-meta text-success"
        >{gettext("saved")}</span>
      </:bar>
      <div
        id="persona-editor"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-3xl flex-col gap-4 overflow-y-auto px-4 py-6"
      >
        <form id="soul-form" phx-submit="save" class="flex flex-col gap-3">
          <label class="text-meta opacity-70">{gettext(
            "SOUL (markdown): who this persona is, how it works, its boundaries"
          )}</label>
          <textarea
            id="soul"
            name="persona[soul]"
            rows="18"
            class="w-full rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
          >{@persona.soul}</textarea>
          <div class="flex items-center gap-3">
            <label class="text-meta opacity-70">{gettext("Default model")}</label>
            <select
              name="persona[model]"
              class="rounded-field border border-base-300 bg-base-100 px-2 py-1 text-meta"
            >
              <option value="" selected={is_nil(@persona.model)}>
                {gettext("the registry default")}
              </option>
              <option :for={m <- @models} value={m.id} selected={m.id == @persona.model}>
                {m.id}
              </option>
            </select>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
          </div>
        </form>
        <section class="flex flex-col gap-2">
          <h2 class="text-ui font-semibold">{gettext("Quick settings")}</h2>
          <form id="memory-rule" phx-change="memory_rule" class="flex items-center gap-2 text-meta">
            <label class="opacity-70">{gettext("The memory tool may write")}</label>
            <select
              name="rule"
              class="rounded-field border border-base-300 bg-base-100 px-2 py-1 text-meta"
            >
              <option :for={r <- ~w(allow ask deny)} value={r} selected={r == memory_rule(@persona)}>
                {r}
              </option>
            </select>
          </form>
          <p class="text-meta opacity-70">
            {gettext(
              "Changes take effect in the next session; running sessions keep the prompt they started with."
            )}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp memory_rule(%{settings: %{"permissions" => %{"memory" => r}}}), do: r
  defp memory_rule(_), do: "ask"
end
