# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.PermissionsLive do
  @moduledoc """
  `/permissions`: the audit. Slice 021. Every request with its decision, decider and time,
  pending ones first and decidable here too; then the rules and grants, each revocable.
  Everything this page does is `Trinity.Permissions.decide_request/3` or `revoke_rule/1`.
  """
  use TrinityWeb, :live_view

  import TrinityWeb.ApprovalComponents

  alias Trinity.Permissions
  alias Trinity.Permissions.Approval

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Permissions.subscribe(:all)
    {:ok, socket |> assign(page_title: gettext("Permissions"), patterns: %{}) |> load()}
  end

  defp load(socket) do
    assign(socket,
      pending: Permissions.pending(:all),
      approvals: Permissions.list_approvals(limit: 200),
      rules: Permissions.list_rules()
    )
  end

  @impl true
  def handle_info({:approval, _kind, %Approval{}}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approval_decide", %{"id" => id, "decision" => decision}, socket)
      when decision in ["once", "session", "always", "deny"] do
    opts =
      if decision == "always", do: [pattern: Map.get(socket.assigns.patterns, id, "*")], else: []

    case Permissions.decide_request(id, String.to_existing_atom(decision), opts) do
      {:ok, _} ->
        {:noreply, load(socket)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Not decided: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("approval_pattern", %{"approval_id" => id, "pattern" => pattern}, socket),
    do: {:noreply, assign(socket, patterns: Map.put(socket.assigns.patterns, id, pattern))}

  # Slice 060: a server's input request, answered from the card's form; the answer travels
  # with the decision, and the retry the Session makes carries it to the server.
  def handle_event("approval_answer", %{"approval_id" => id} = params, socket) do
    with %Approval{} = approval <- Permissions.get_approval(id),
         answer = answer_from_params(approval, params),
         {:ok, _} <- Permissions.decide_request(id, :once, answer: answer) do
      {:noreply, load(socket)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That request is gone."))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Not decided: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    _ = Permissions.revoke_rule(id)
    {:noreply, load(socket)}
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Permissions")}</span>
        <.pending_indicator count={length(@pending)} />
      </:bar>
      <div
        id="permissions"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-4xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <section :if={@pending != []} class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{gettext("Waiting for a decision")}</h2>
          <.approval_card :for={a <- @pending} approval={a} pattern={Map.get(@patterns, a.id)} />
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Decisions")}</h2>
          <p :if={@approvals == []} class="opacity-70">{gettext("No request has been made yet.")}</p>
          <table :if={@approvals != []} id="approvals" class="w-full table-fixed text-ui">
            <colgroup>
              <col class="w-40" />
              <col class="w-28" />
              <col class="w-20" />
              <col />
              <col class="w-36" />
              <col class="w-20" />
            </colgroup>
            <thead class="text-meta uppercase tracking-wide opacity-70">
              <tr>
                <th class="py-1 text-left">{gettext("When")}</th>
                <th class="py-1 text-left">{gettext("Tool")}</th>
                <th class="py-1 text-left">{gettext("Risk")}</th>
                <th class="py-1 text-left">{gettext("Arguments")}</th>
                <th class="py-1 text-left">{gettext("Decision")}</th>
                <th class="py-1 text-left">{gettext("By")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={a <- @approvals}
                id={"approval-row-#{a.id}"}
                class="border-t border-base-300 align-top"
              >
                <td class="py-2 pr-3 whitespace-nowrap font-mono text-meta">
                  {stamp(a.decided_at || a.inserted_at)}
                </td>
                <td class="py-2 pr-3 font-mono">{a.tool}</td>
                <td class="py-2 pr-3"><.risk_badge risk={a.risk} /></td>
                <td class="py-2 pr-3 font-mono text-meta">
                  <div class="truncate" title={Jason.encode!(a.args)}>{Jason.encode!(a.args)}</div>
                </td>
                <td class="py-2 pr-3">
                  <span class={[
                    "rounded-pill px-2 py-0.5 text-meta",
                    a.status == "pending" && "bg-warning/20 text-warning",
                    a.status == "allowed" && "bg-success/20 text-success",
                    a.status in ["denied", "expired"] && "bg-error/20 text-error"
                  ]}>
                    {a.status}{if a.decision, do: " · " <> a.decision}
                  </span>
                </td>
                <td class="py-2 text-meta opacity-70">{a.decided_by}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Rules and grants")}</h2>
          <p :if={@rules == []} class="opacity-70">
            {gettext("None. Always allow and allow for this session write one.")}
          </p>
          <table :if={@rules != []} id="rules" class="w-full table-fixed text-ui">
            <colgroup>
              <col class="w-28" />
              <col />
              <col class="w-20" />
              <col class="w-40" />
              <col class="w-40" />
              <col class="w-20" />
            </colgroup>
            <thead class="text-meta uppercase tracking-wide opacity-70">
              <tr>
                <th class="py-1 text-left">{gettext("Tool")}</th>
                <th class="py-1 text-left">{gettext("Pattern")}</th>
                <th class="py-1 text-left">{gettext("Decision")}</th>
                <th class="py-1 text-left">{gettext("Scope")}</th>
                <th class="py-1 text-left">{gettext("Expires")}</th>
                <th class="py-1"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @rules} id={"rule-#{r.id}"} class="border-t border-base-300">
                <td class="py-2 pr-3 font-mono">{r.tool}</td>
                <td class="py-2 pr-3 font-mono text-meta">
                  <div class="truncate" title={r.pattern}>{r.pattern}</div>
                </td>
                <td class="py-2 pr-3">{r.decision}</td>
                <td class="py-2 pr-3 font-mono text-meta">{r.scope}</td>
                <td class="py-2 pr-3 font-mono text-meta">{stamp(r.expires_at)}</td>
                <td class="py-2 text-right">
                  <button
                    type="button"
                    phx-click="revoke"
                    phx-value-id={r.id}
                    class="cursor-pointer rounded-pill border border-error/50 px-2 py-0.5 text-meta text-error hover:bg-error/10"
                  >
                    {gettext("Revoke")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp stamp(nil), do: ""
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M") <> " UTC"
end
