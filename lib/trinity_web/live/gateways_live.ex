# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.GatewaysLive do
  @moduledoc """
  `/gateways` (slice 070): the channels Trinity can be reached from, who is waiting to be paired,
  and who has been let in.

  The pairing code is shown here and nowhere else, which is the whole of the pairing proof: a
  sender who can read this page is at the owner's desktop. Each identity can be allowed without a
  code or revoked, and a revoked row stays visible rather than disappearing, so turning someone
  away is a thing the page records rather than a thing it forgets. The tier ceiling each adapter
  carries is shown beside it, because what a channel may approve is the question this page is
  really about (docs/07, the channel trust cap).
  """
  use TrinityWeb, :live_view

  alias Trinity.Gateways
  alias Trinity.Gateways.{Adapter, Cap, Identities}

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, socket |> assign(page_title: gettext("Gateways")) |> load()}
  end

  defp load(socket) do
    assign(socket,
      adapters: adapters(),
      identities: Identities.list(),
      ttl_minutes: div(Identities.code_ttl_s(), 60)
    )
  end

  defp adapters do
    for adapter <- Gateways.adapters() do
      %{
        module: adapter,
        name: Adapter.name(adapter),
        running?: is_pid(Process.whereis(adapter)),
        ceiling: Cap.ceiling(adapter),
        capabilities: adapter.capabilities()
      }
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("allow", %{"id" => id}, socket),
    do: {:noreply, act(socket, id, &Identities.allow/1)}

  def handle_event("revoke", %{"id" => id}, socket),
    do: {:noreply, act(socket, id, &Identities.revoke/1)}

  defp act(socket, id, fun) do
    case Enum.find(socket.assigns.identities, &(&1.id == id)) do
      nil -> put_flash(socket, :error, gettext("That identity is gone."))
      identity -> with({:ok, _} <- fun.(identity), do: load(socket))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Gateways")}</span>
        <span class="font-mono text-meta opacity-70">{length(@identities)}</span>
      </:bar>
      <div
        id="gateways"
        class="mx-auto flex h-full max-w-4xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Channels")}</h2>
          <p :if={@adapters == []} class="opacity-70">
            {gettext(
              "No gateway is configured. A channel is a module in config :trinity, :gateways, adapters: [...]; the console adapter ships with Trinity and is what mix trinity.console talks to."
            )}
          </p>
          <ul id="adapter-list" class="flex flex-col gap-2">
            <li
              :for={adapter <- @adapters}
              id={"adapter-#{adapter.name}"}
              class="flex flex-wrap items-center gap-2 rounded-field border border-base-300 px-3 py-2"
            >
              <span class="font-mono font-semibold">{adapter.name}</span>
              <span class={[
                "rounded-pill px-2 py-0.5 text-meta",
                adapter.running? && "bg-success/20 text-success",
                !adapter.running? && "bg-base-300 opacity-70"
              ]}>
                {if adapter.running?, do: gettext("running"), else: gettext("not started")}
              </span>
              <span class="text-meta opacity-70">
                {gettext("approves up to")}
                <span class="font-mono">{adapter.ceiling}</span>
              </span>
              <span class="text-meta opacity-70">
                {gettext("max")}
                <span class="font-mono">{adapter.capabilities.max_length}</span>
              </span>
            </li>
          </ul>
          <p class="text-meta opacity-70">
            {gettext(
              "A channel may approve up to its ceiling and no further: an exec or destructive request is decided on the desktop, on the permissions page. The gate still decides every call whatever the channel."
            )}
          </p>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Waiting to pair")}</h2>
          <p :if={pending(@identities) == []} class="opacity-70">
            {gettext("Nobody is waiting. An unknown sender is shown a code here when they write.")}
          </p>
          <ul id="pending-list" class="flex flex-col gap-2">
            <li
              :for={identity <- pending(@identities)}
              id={"identity-#{identity.id}"}
              class="flex flex-wrap items-center gap-3 rounded-field border border-warning/40 px-3 py-2"
            >
              <span class="font-mono text-lg tracking-widest">{identity.code}</span>
              <span class="font-mono text-meta opacity-70">
                {identity.adapter}:{identity.external_user_id}
              </span>
              <span :if={identity.display_name} class="text-meta opacity-70">
                {identity.display_name}
              </span>
              <span class="flex-1"></span>
              <span class="text-meta opacity-70">
                {gettext("expires in %{n} minutes", n: @ttl_minutes)}
              </span>
              <button phx-click="allow" phx-value-id={identity.id} class="btn btn-xs btn-primary">
                {gettext("allow")}
              </button>
              <button
                phx-click="revoke"
                phx-value-id={identity.id}
                class="btn btn-xs btn-ghost text-error"
              >
                {gettext("revoke")}
              </button>
            </li>
          </ul>
          <p class="text-meta opacity-70">
            {gettext(
              "Send the code from the channel to pair, or allow it here. Until then that sender gets the pairing prompt and nothing else: no session, no model."
            )}
          </p>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Identities")}</h2>
          <table :if={@identities != []} class="w-full text-ui">
            <tbody>
              <tr
                :for={identity <- @identities}
                id={"row-#{identity.id}"}
                class="border-t border-base-300"
              >
                <td class="py-1 pr-3 font-mono">{identity.adapter}</td>
                <td class="py-1 pr-3 font-mono">{identity.external_user_id}</td>
                <td class="py-1 pr-3 font-mono text-meta">{identity.state}</td>
                <td class="py-1 pr-3 text-meta opacity-70">{identity.display_name}</td>
                <td class="py-1 text-right">
                  <button
                    :if={identity.state != "paired"}
                    phx-click="allow"
                    phx-value-id={identity.id}
                    class="btn btn-xs btn-ghost"
                  >
                    {gettext("allow")}
                  </button>
                  <button
                    :if={identity.state != "revoked"}
                    phx-click="revoke"
                    phx-value-id={identity.id}
                    data-confirm={gettext("Turn this identity away?")}
                    class="btn btn-xs btn-ghost text-error"
                  >
                    {gettext("revoke")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@identities == []} class="opacity-70">
            {gettext("No identity has written yet.")}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp pending(identities), do: Enum.filter(identities, &(&1.state == "pending" and &1.code))
end
