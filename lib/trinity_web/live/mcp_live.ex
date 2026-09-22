# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.MCPLive do
  @moduledoc """
  `/mcp` (slice 060): the configured MCP servers with their health (status, the revision
  chosen, the tools registered, the last error), each with enable, disable, reconnect and
  remove; the tools of a server with their effect and tier; and a form to add a server
  (stdio: a command with arguments and the environment variables to pass; http: a URL).
  Everything here is `Trinity.MCP.Servers`; the page refreshes itself every two seconds
  while open, since a client's health changes on its own. Slice 062: a server that answered
  `401` with a resource metadata URL shows the challenge and "authorize", which begins the
  client role's flow (`Trinity.MCP.AuthHost.client_begin/2`) and sends the owner to the
  authorization server; the callback lands at `/oauth/callback` and returns here.
  """
  use TrinityWeb, :live_view

  alias Trinity.MCP.{AuthHost, Client, ServerConfig, Servers}
  alias Trinity.Tools

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(
       page_title: gettext("MCP servers"),
       form: to_form(%{"transport" => "stdio"}),
       viewing: nil
     )
     |> load()}
  end

  defp load(socket) do
    assign(socket, servers: Servers.status())
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("create", %{"server" => params}, socket) do
    case Servers.create(attrs(params)) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(form: to_form(%{"transport" => "stdio"}))
         |> put_flash(:info, gettext("Server %{name} added.", name: config.name))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(params, errors: errors(changeset)))}
    end
  end

  def handle_event("transport", %{"server" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(params))}

  def handle_event("enable", %{"id" => id}, socket), do: {:noreply, set_enabled(socket, id, true)}

  def handle_event("disable", %{"id" => id}, socket),
    do: {:noreply, set_enabled(socket, id, false)}

  def handle_event("reconnect", %{"name" => name}, socket) do
    _ = Client.reconnect(name)
    {:noreply, load(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    with %ServerConfig{} = config <- Servers.get(id), {:ok, _} <- Servers.delete(config) do
      {:noreply, socket |> assign(viewing: nil) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not removed."))}
    end
  end

  def handle_event("authorize", %{"prm" => prm_url}, socket) do
    case AuthHost.client_begin(prm_url, redirect_uri: url(~p"/oauth/callback")) do
      {:ok, authorize_url} ->
        {:noreply, redirect(socket, external: authorize_url)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Authorization could not begin: %{reason}", reason: AuthHost.describe(reason))
         )}
    end
  end

  def handle_event("view", %{"name" => name}, socket),
    do: {:noreply, assign(socket, viewing: name)}

  def handle_event("hide", _params, socket), do: {:noreply, assign(socket, viewing: nil)}

  defp set_enabled(socket, id, enabled) do
    with %ServerConfig{} = config <- Servers.get(id),
         {:ok, _} <- Servers.update(config, %{enabled: enabled}) do
      load(socket)
    else
      _ -> put_flash(socket, :error, gettext("Not changed."))
    end
  end

  # The form's strings to the row's attributes: arguments split on whitespace, env refs on
  # commas or whitespace, blanks dropped.
  defp attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      transport: params["transport"],
      command: blank_to_nil(params["command"]),
      args: words(params["args"]),
      url: blank_to_nil(params["url"]),
      env_refs: params["env_refs"] |> to_string() |> String.split(~r/[\s,]+/, trim: true),
      effect_default: params["effect_default"] || "none"
    }
  end

  defp words(nil), do: []
  defp words(s), do: String.split(s, ~r/\s+/, trim: true)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp errors(changeset) do
    for {field, {msg, _}} <- changeset.errors, do: {field, {msg, []}}
  end

  defp tools_of(name) do
    Tools.list() |> Enum.filter(&String.starts_with?(&1.name, "mcp:" <> name <> ":"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("MCP servers")}</span>
        <span class="font-mono text-meta opacity-70">{length(@servers)}</span>
      </:bar>
      <div
        id="mcp"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-4xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Servers")}</h2>
          <p :if={@servers == []} class="opacity-70">
            {gettext(
              "No server is configured. Add one below; its tools appear to the assistant as mcp:<server>:<tool>, each asking for approval until you write a rule."
            )}
          </p>
          <ul id="server-list" class="flex flex-col gap-2">
            <li
              :for={%{config: c, client: info} <- @servers}
              id={"server-#{c.name}"}
              class="flex flex-col gap-2 rounded-field border border-base-300 px-3 py-2"
            >
              <div class="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  phx-click="view"
                  phx-value-name={c.name}
                  class="font-mono font-semibold"
                >
                  {c.name}
                </button>
                <span class="font-mono text-meta opacity-70">{c.transport}</span>
                <.status status={status_of(c, info)} />
                <span :if={info && info.revision} class="font-mono text-meta">{info.revision}</span>
                <span :if={info} class="font-mono text-meta opacity-70">
                  {ngettext("%{count} tool", "%{count} tools", length(info.registered))}
                </span>
                <span class="flex-1"></span>
                <button
                  :if={c.enabled}
                  phx-click="reconnect"
                  phx-value-name={c.name}
                  class="btn btn-xs btn-ghost"
                >
                  {gettext("reconnect")}
                </button>
                <button
                  :if={c.enabled}
                  phx-click="disable"
                  phx-value-id={c.id}
                  class="btn btn-xs btn-ghost"
                >
                  {gettext("disable")}
                </button>
                <button
                  :if={!c.enabled}
                  phx-click="enable"
                  phx-value-id={c.id}
                  class="btn btn-xs btn-ghost"
                >
                  {gettext("enable")}
                </button>
                <button
                  phx-click="remove"
                  phx-value-id={c.id}
                  data-confirm={gettext("Remove this server and its tools?")}
                  class="btn btn-xs btn-ghost text-error"
                >
                  {gettext("remove")}
                </button>
              </div>
              <p class="font-mono text-meta opacity-70">
                {if c.transport == "stdio", do: Enum.join([c.command | c.args], " "), else: c.url}
              </p>
              <p :if={info && info.last_error} class="font-mono text-meta text-error">
                {info.last_error}
              </p>
              <div
                :if={info && info.auth_challenge}
                class="flex flex-wrap items-center gap-2 text-meta"
              >
                <span class="opacity-70">{gettext("Needs authorization")}</span>
                <span class="font-mono opacity-70">{info.auth_challenge}</span>
                <button
                  phx-click="authorize"
                  phx-value-prm={info.auth_challenge}
                  class="btn btn-xs btn-primary"
                >
                  {gettext("authorize")}
                </button>
              </div>
              <div :if={@viewing == c.name} class="flex flex-col gap-1 border-t border-base-300 pt-2">
                <div class="flex items-center gap-2">
                  <span class="text-meta opacity-70">{gettext("Tools")}</span>
                  <button phx-click="hide" class="btn btn-xs btn-ghost">{gettext("hide")}</button>
                </div>
                <p :if={tools_of(c.name) == []} class="text-meta opacity-70">
                  {gettext("None registered.")}
                </p>
                <table :if={tools_of(c.name) != []} class="w-full text-ui">
                  <tbody>
                    <tr :for={t <- tools_of(c.name)} class="border-t border-base-300 align-top">
                      <td class="py-1 pr-3 font-mono">{t.name}</td>
                      <td class="py-1 pr-3 font-mono text-meta">{t.effect}</td>
                      <td class="py-1 pr-3 font-mono text-meta">{t.risk}</td>
                      <td class="py-1 text-meta opacity-70">
                        {t.spec && t.spec.description}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </li>
          </ul>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Add a server")}</h2>
          <.form
            for={@form}
            id="server-form"
            as={:server}
            phx-change="transport"
            phx-submit="create"
            class="flex flex-col gap-2"
          >
            <div class="flex flex-wrap gap-2">
              <input
                name="server[name]"
                value={@form[:name].value}
                placeholder={gettext("name (a-z, 0-9, -, _)")}
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
              />
              <select
                name="server[transport]"
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
              >
                <option
                  :for={t <- ServerConfig.transports()}
                  value={t}
                  selected={@form[:transport].value == t}
                >
                  {t}
                </option>
              </select>
              <select
                name="server[effect_default]"
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
              >
                <option
                  :for={e <- ServerConfig.effects()}
                  value={e}
                  selected={@form[:effect_default].value == e}
                >
                  {gettext("effect")}: {e}
                </option>
              </select>
            </div>
            <div :if={@form[:transport].value == "stdio"} class="flex flex-wrap gap-2">
              <input
                name="server[command]"
                value={@form[:command].value}
                placeholder={gettext("command")}
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
              <input
                name="server[args]"
                value={@form[:args].value}
                placeholder={gettext("arguments")}
                class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
              <input
                name="server[env_refs]"
                value={@form[:env_refs].value}
                placeholder={gettext("environment variables to pass, by name")}
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
            </div>
            <div :if={@form[:transport].value == "http"} class="flex flex-wrap gap-2">
              <input
                name="server[url]"
                value={@form[:url].value}
                placeholder="https://host/mcp"
                class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
            </div>
            <p :for={{field, {msg, _}} <- @form.errors} class="text-meta text-error">
              {field}: {msg}
            </p>
            <div>
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Add")}</button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp status_of(%ServerConfig{enabled: false}, _info), do: :disabled
  defp status_of(_config, nil), do: :stopped
  defp status_of(_config, %{status: status}), do: status

  attr :status, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={[
      "rounded-pill px-2 py-0.5 text-meta font-semibold uppercase tracking-wide",
      @status == :ready && "bg-success/20 text-success",
      @status in [:connecting, :down] && "bg-warning/20 text-warning",
      @status == :refused && "bg-error/20 text-error",
      @status in [:disabled, :stopped] && "bg-base-300"
    ]}>
      {@status}
    </span>
    """
  end
end
