# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SetupLive do
  @moduledoc """
  `/setup`, the first-run path (slice 100, AC11). On a machine with nothing configured the chat
  cannot answer: no key, no model, no confirmed data directory, no folder the tools may use. Three
  steps, reusing the Settings page's pieces (`TrinityWeb.SettingsComponents`), and then a session:

    1. a model and its key (the key goes to the keychain, as on Settings);
    2. the data directory, shown and confirmed;
    3. the first project folders (the native dialog, or typed).

  `/` sends a visitor here while `Trinity.Setup.needed?/0`; finishing records the model as the
  default and the setup as done, and opens a new session.
  """
  use TrinityWeb, :live_view

  import TrinityWeb.SettingsComponents

  alias Trinity.{Secrets, Sessions, Setup}
  alias TrinityWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    models = Enum.filter(Trinity.LLM.models(), &(:stream in Map.get(&1, :caps, [])))
    default = Trinity.LLM.default_model()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Set up Trinity"),
       models: models,
       model_id: default,
       model_ok: false,
       model_error: nil,
       keychain?: Secrets.keychain_available?(),
       data_dir: Trinity.Paths.data_dir(),
       data_dir_ok: false
     )
     |> SettingsComponents.assign_roots()}
  end

  @impl true
  def handle_event("choose_model", %{"setup" => %{"model" => id} = params}, socket) do
    case Enum.find(socket.assigns.models, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, model_error: gettext("Choose a model from the list."))}

      model ->
        {:noreply, choose(socket, model, String.trim(Map.get(params, "secret", "")))}
    end
  end

  def handle_event("confirm_data_dir", _params, socket),
    do: {:noreply, assign(socket, data_dir_ok: true)}

  def handle_event("add_root", %{"root" => root}, socket),
    do: {:noreply, SettingsComponents.add_root(socket, root)}

  def handle_event("remove_root", %{"root" => root}, socket),
    do: {:noreply, SettingsComponents.remove_root(socket, root)}

  def handle_event("pick_root", _params, socket),
    do: {:noreply, SettingsComponents.pick_root(socket)}

  def handle_event("finish", _params, %{assigns: %{model_ok: true, data_dir_ok: true}} = socket) do
    :ok = Setup.complete(socket.assigns.model_id)

    case Sessions.create_session(%{persona_id: Sessions.default_persona().id, origin: "desktop"}) do
      {:ok, session} -> {:noreply, push_navigate(socket, to: ~p"/s/#{session.id}")}
      {:error, _} -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_event("finish", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:pick_root, result, socket),
    do: {:noreply, SettingsComponents.picked(socket, result)}

  # A model that needs a key gets one now, or must already have one; nothing is stored anywhere
  # but the keychain.
  defp choose(socket, model, key) do
    name = Map.get(model, :api_key_env)

    stored = if name == nil or key == "", do: :ok, else: Secrets.store(name, key)

    cond do
      stored == {:error, :keychain_unavailable} ->
        assign(socket,
          model_ok: false,
          model_error:
            gettext("No keychain in this run: set %{name} in the environment and reload.",
              name: name
            )
        )

      match?({:error, _}, stored) ->
        assign(socket, model_ok: false, model_error: gettext("The keychain refused the key."))

      not Setup.model_ready?(model) ->
        assign(socket,
          model_ok: false,
          model_error: gettext("%{id} needs a key (%{name}).", id: model.id, name: name)
        )

      true ->
        assign(socket, model_id: model.id, model_ok: true, model_error: nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar><span class="opacity-70">{gettext("Set up Trinity")}</span></:bar>
      <div id="setup" class="mx-auto flex h-full max-w-3xl flex-col gap-6 overflow-y-auto px-4 py-6">
        <p class="text-ui opacity-80">
          {gettext(
            "Three things before the first conversation. Each can be changed later in Settings."
          )}
        </p>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("1. A model, and its key")}</h2>
          <form
            id="setup-model"
            phx-submit="choose_model"
            class="flex flex-wrap items-center gap-2"
            autocomplete="off"
          >
            <select name="setup[model]" class="select select-sm w-64">
              <option :for={m <- @models} value={m.id} selected={m.id == @model_id}>{m.id}</option>
            </select>
            <input
              type="password"
              name="setup[secret]"
              value=""
              autocomplete="off"
              disabled={!@keychain?}
              placeholder={if @keychain?, do: gettext("its key"), else: gettext("no keychain")}
              class="input input-sm w-64"
            />
            <button type="submit" class="btn btn-sm">{gettext("Use this model")}</button>
          </form>
          <p :if={@model_error} class="text-meta text-error">{@model_error}</p>
          <p :if={@model_ok} id="setup-model-ok" class="text-meta text-success">
            {gettext("%{id} is ready.", id: @model_id)}
          </p>
        </section>

        <section id="setup-data-dir" class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("2. Where Trinity keeps its data")}</h2>
          <code class="break-all text-meta">{@data_dir}</code>
          <div class="flex items-center gap-2">
            <button :if={!@data_dir_ok} type="button" phx-click="confirm_data_dir" class="btn btn-sm">
              {gettext("Use this folder")}
            </button>
            <span :if={@data_dir_ok} class="text-meta text-success">{gettext("Confirmed.")}</span>
          </div>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("3. Project folders (optional)")}</h2>
          <p class="text-ui opacity-80">
            {gettext(
              "The file tools may read and write in these without asking. You can add more later."
            )}
          </p>
          <.roots roots={@roots} root_error={@root_error} />
        </section>

        <button
          :if={@model_ok and @data_dir_ok}
          id="setup-finish"
          type="button"
          phx-click="finish"
          class="btn btn-primary self-start"
        >
          {gettext("Start a conversation")}
        </button>
      </div>
    </Layouts.app>
    """
  end
end
