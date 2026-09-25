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
  alias Trinity.Tools.{DefinitionDigest, Surface}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Permissions.subscribe(:all)
    {:ok, socket |> assign(page_title: gettext("Permissions"), patterns: %{}) |> load()}
  end

  defp load(socket) do
    assign(socket,
      pending: Permissions.pending(:all),
      approvals: Permissions.list_approvals(limit: 200),
      rules: Permissions.list_rules(),
      # Slice 029: tools held because a server changed their definition after the owner approved
      # them. They are here rather than on /mcp because this is the page Trinity asks the owner
      # things on, and a notice on a page visited only when adding a server is a notice missed.
      drifting: Surface.drifting(),
      # Slice 042. These are decisions about the *population* of future asks, and they are rendered
      # in their own sections precisely so they are read in a calm moment rather than beside a
      # pending one. Nothing here reaches the approval card, which a census asserts.
      proposals: Permissions.proposals(),
      divergences: Permissions.divergences()
    )
  end

  @doc false
  def drift_changes(%Surface{definition: was, pending_definition: now}),
    do: DefinitionDigest.changes(was || %{}, now || %{})

  # A tool definition arrived as JSON and is read by a person as JSON. Rendering a schema with
  # `inspect/1` makes the reader parse Elixir map syntax to answer a question about a JSON
  # document, which is work this page should be doing. Strings stay bare: quoting a description
  # buys nothing and makes the diff harder to read.
  @doc false
  def drift_value(value) when is_binary(value), do: value
  def drift_value(nil), do: "(absent)"

  def drift_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
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

  # Slice 029. Accepting makes the changed definition the new baseline, so the tool registers on
  # the next listing. Dismissing clears the notice and leaves the baseline standing, so the tool
  # stays held and the next listing raises it again: dismissing is not deciding.
  def handle_event("drift_accept", %{"server" => server, "tool" => tool}, socket) do
    case Surface.get(server, tool) do
      %Surface{pending_definition: nil} ->
        {:noreply, load(socket)}

      %Surface{pending_definition: pending} ->
        {:ok, _} = Surface.accept(server, tool, pending)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Accepted. The tool loads on the next listing."))
         |> load()}

      nil ->
        {:noreply, load(socket)}
    end
  end

  # Slice 042: accepting a proposal writes an ordinary rule through the ordinary path. There is no
  # second kind of rule, and the owner could have written this one by hand.
  def handle_event("proposal_accept", %{"tool" => tool, "decision" => decision}, socket) do
    case Permissions.put_rule(%{
           tool: tool,
           pattern: "*",
           decision: decision,
           decided_by: "owner (from #{length(socket.assigns.proposals)} proposals)"
         }) do
      {:ok, rule} ->
        receipt_proposal(rule, tool, decision, socket.assigns.proposals)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Rule written. Trinity will stop asking about %{tool}.", tool: tool)
         )
         |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not write that rule."))}
    end
  end

  def handle_event("drift_dismiss", %{"server" => server, "tool" => tool}, socket) do
    Surface.dismiss(server, tool)

    {:noreply,
     socket |> put_flash(:info, gettext("Left held. The tool stays unavailable.")) |> load()}
  end

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

  # Slice 042 AC6. A rule written from a proposal is a change to standing authority made by the
  # owner, so it goes in the chain with the evidence it rested on: the count, and that a proposal is
  # what prompted it. Without the count a reader cannot tell a rule the owner typed from one they
  # accepted, and those are different acts.
  defp receipt_proposal(rule, tool, decision, proposals) do
    count =
      case Enum.find(proposals, &(&1.tool == tool)) do
        %{count: n} -> n
        nil -> 0
      end

    Trinity.Receipts.append(Trinity.Receipts.policy_scope(), %{
      kind: "decision",
      subject: %{"tool" => tool, "rule_id" => rule.id, "phase" => "rule"},
      decision: %{
        "outcome" => decision,
        "basis" => "proposal",
        "reason" => "accepted a proposal drawn from #{count} decisions that agreed"
      },
      subject_ref: "rule:" <> tool,
      meta: %{"decisions" => count, "pattern" => rule.pattern}
    })
  end

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
        <section :if={@proposals != []} id="proposals" class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{gettext("Rules your decisions imply")}</h2>
          <p class="text-sm opacity-70">
            {gettext(
              "You have decided these the same way every time. Writing a rule stops Trinity asking again. Nothing here appears beside a pending request: a suggestion offered at the moment of deciding would change the decision."
            )}
          </p>

          <article
            :for={p <- @proposals}
            id={"proposal-#{p.tool}"}
            class="flex flex-wrap items-center gap-3 rounded-box border border-base-300 p-3"
          >
            <span class="font-mono text-sm">{p.tool}</span>
            <span class={[
              "rounded-pill px-2 py-0.5 text-meta",
              p.decision == "allow" && "bg-success/20 text-success",
              p.decision == "deny" && "bg-error/20 text-error"
            ]}>
              {p.decision}
            </span>
            <span class="text-meta opacity-70">
              {gettext("every one of")} {p.count} {gettext("decisions")}
            </span>
            <span class="flex-1"></span>
            <button
              type="button"
              phx-click="proposal_accept"
              phx-value-tool={p.tool}
              phx-value-decision={p.decision}
              class="btn btn-sm"
            >
              {gettext("Write the rule")}
            </button>
          </article>
        </section>

        <section :if={@divergences != []} id="divergences" class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Decisions that did not agree")}</h2>
          <p class="text-sm opacity-70">
            {gettext(
              "No rule is offered for these, because one would permit the case you refused. Shown so you can see where your own answers differ."
            )}
          </p>
          <ul class="flex flex-col gap-1">
            <li :for={d <- @divergences} class="flex items-center gap-3 text-sm">
              <span class="min-w-0 flex-1 truncate font-mono">{d.tool}</span>
              <span :for={{status, n} <- Enum.sort(d.counts)} class="font-mono text-meta opacity-70">
                {status} {n}
              </span>
            </li>
          </ul>
        </section>

        <section :if={@drifting != []} id="drift" class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{gettext("Tool definitions that changed")}</h2>
          <p class="text-sm opacity-70">
            {gettext(
              "These tools are held and cannot be called. A server changed what they say after you approved them."
            )}
          </p>

          <article
            :for={d <- @drifting}
            id={"drift-#{d.server}-#{d.tool}"}
            class="rounded-box border border-warning bg-warning/5 p-3"
          >
            <header class="flex items-baseline gap-2">
              <span class="font-mono text-sm">{d.server}:{d.tool}</span>
              <span class="flex-1"></span>
              <span class="text-meta opacity-60">
                {gettext("held since")} {Calendar.strftime(d.pending_since, "%Y-%m-%d %H:%M")}
              </span>
            </header>

            <dl class="mt-2 flex flex-col gap-2">
              <div :for={{field, was, now} <- drift_changes(d)} class="text-sm">
                <dt class="font-mono text-meta opacity-70">{field}</dt>
                <dd class="mt-0.5 flex flex-col gap-0.5 font-mono text-meta">
                  <span class="text-error">- {drift_value(was)}</span>
                  <span class="text-success">+ {drift_value(now)}</span>
                </dd>
              </div>
            </dl>

            <div class="mt-3 flex gap-2">
              <button
                type="button"
                phx-click="drift_accept"
                phx-value-server={d.server}
                phx-value-tool={d.tool}
                class="btn btn-sm"
              >
                {gettext("Accept the change")}
              </button>
              <button
                type="button"
                phx-click="drift_dismiss"
                phx-value-server={d.server}
                phx-value-tool={d.tool}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Leave it held")}
              </button>
            </div>
          </article>
        </section>

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
