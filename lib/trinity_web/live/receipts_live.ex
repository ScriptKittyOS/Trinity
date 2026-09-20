# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ReceiptsLive do
  @moduledoc """
  `/s/:id/receipts` and `/receipts/boot` (slice 024): one chain scope's receipts in seq order
  with their kind, subject, decision, hash prefix and whether they are signed or
  checkpointed; the checkpoints; and a verify button that runs `Trinity.Receipts.Verifier`
  over the scope's export and shows the outcome with its exit code. The boot page is the boot
  receipt of this run at the top of the boot chain (SLICE.md says Settings; there is no
  Settings page in this tree yet, so the boot receipt has its own route). The page reads and
  verifies; it writes nothing, because nothing on a page may.
  """
  use TrinityWeb, :live_view

  alias Trinity.Receipts
  alias Trinity.Receipts.Verifier

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(
       scope: Receipts.session_scope(id),
       session_id: id,
       boot?: false,
       page_title: gettext("Receipts")
     )
     |> load()}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       scope: Receipts.boot_scope(),
       session_id: nil,
       boot?: true,
       page_title: gettext("Boot receipt")
     )
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.scope

    assign(socket,
      receipts: Receipts.list(scope) |> Enum.reverse(),
      checkpoints: Receipts.checkpoints(scope),
      boot: if(socket.assigns.boot?, do: Receipts.boot_receipt()),
      verified: nil
    )
  end

  @impl true
  def handle_event("verify", _params, socket) do
    outcome =
      case Receipts.export(socket.assigns.scope) do
        {:ok, export} -> Verifier.verify(export, require_coverage: false)
        {:error, reason} -> {:error, 2, reason}
      end

    {:noreply, assign(socket, verified: outcome)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{if @boot?, do: gettext("Boot receipt"), else: gettext("Receipts")}</span>
        <span class="truncate font-mono text-meta opacity-70">{@scope}</span>
        <.link :if={@session_id} navigate={~p"/s/#{@session_id}"} class="text-meta underline">
          {gettext("back to the session")}
        </.link>
      </:bar>
      <div
        id="receipts"
        class="mx-auto flex h-full max-w-5xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <section :if={@boot?} class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("This run")}</h2>
          <p :if={is_nil(@boot)} id="no-boot" class="opacity-70">
            {gettext("No boot receipt was written this run: no signer was available at boot.")}
          </p>
          <dl
            :if={@boot}
            id="boot-receipt"
            class="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-1 font-mono text-meta"
          >
            <dt class="opacity-70">{gettext("authority")}</dt>
            <dd>{@boot.subject["authority"]}</dd>
            <dt class="opacity-70">{gettext("signer")}</dt>
            <dd>
              {@boot.subject["signer"]["algorithm"]} · {@boot.subject["signer"]["scheme"]} · {@boot.subject[
                "signer"
              ]["key_id"]}
            </dd>
            <dt class="opacity-70">{gettext("fips")}</dt>
            <dd>{@boot.subject["fips"]}</dd>
            <dt class="opacity-70">{gettext("otp")}</dt>
            <dd>{@boot.subject["otp_release"]}</dd>
            <dt class="opacity-70">{gettext("core policy hash")}</dt>
            <dd class="break-all">{@boot.meta["core_policy_hash"]}</dd>
            <dt class="opacity-70">{gettext("receipt hash")}</dt>
            <dd class="break-all">{@boot.receipt_hash}</dd>
            <dt class="opacity-70">{gettext("at")}</dt>
            <dd>{stamp(@boot.inserted_at)}</dd>
          </dl>
        </section>

        <section class="flex flex-col gap-2">
          <div class="flex items-center gap-3">
            <h2 class="text-lg font-semibold">{gettext("Chain")}</h2>
            <span class="text-meta opacity-70">{length(@receipts)} {gettext("receipts")}, {length(
              @checkpoints
            )} {gettext("checkpoints")}</span>
            <button id="verify" phx-click="verify" class="btn btn-sm">{gettext("Verify")}</button>
            <button phx-click="refresh" class="btn btn-sm btn-ghost">{gettext("Refresh")}</button>
            <.outcome :if={@verified} outcome={@verified} />
          </div>
          <p :if={@receipts == []} class="opacity-70">
            {gettext("Nothing receipted in this scope yet.")}
          </p>
          <table :if={@receipts != []} id="chain" class="w-full table-fixed text-ui">
            <colgroup>
              <col class="w-12" />
              <col class="w-20" />
              <col class="w-40" />
              <col />
              <col class="w-24" />
              <col class="w-36" />
            </colgroup>
            <thead class="text-meta uppercase tracking-wide opacity-70">
              <tr>
                <th class="py-1 text-left">#</th>
                <th class="py-1 text-left">{gettext("Kind")}</th>
                <th class="py-1 text-left">{gettext("Subject")}</th>
                <th class="py-1 text-left">{gettext("Decision")}</th>
                <th class="py-1 text-left">{gettext("Signed")}</th>
                <th class="py-1 text-left">{gettext("Hash")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={r <- @receipts}
                id={"receipt-#{r.seq}"}
                class="border-t border-base-300 align-top"
              >
                <td class="py-2 pr-3 font-mono text-meta">{r.seq}</td>
                <td class="py-2 pr-3"><.kind_badge kind={r.kind} /></td>
                <td class="py-2 pr-3 font-mono text-meta">
                  <div class="truncate" title={Jason.encode!(r.subject)}>{subject(r)}</div>
                </td>
                <td class="py-2 pr-3 font-mono text-meta">
                  <div class="truncate" title={r.signed_payload}>{decision(r)}</div>
                </td>
                <td class="py-2 pr-3 text-meta">
                  {if r.signature, do: gettext("signed"), else: gettext("checkpointed")}
                </td>
                <td class="py-2 font-mono text-meta" title={r.receipt_hash}>
                  {String.slice(r.receipt_hash, 0, 16)}
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section :if={@checkpoints != []} class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Checkpoints")}</h2>
          <table id="checkpoints" class="w-full table-fixed text-ui">
            <thead class="text-meta uppercase tracking-wide opacity-70">
              <tr>
                <th class="py-1 text-left">{gettext("Covers")}</th>
                <th class="py-1 text-left">{gettext("Reason")}</th>
                <th class="py-1 text-left">{gettext("Tail")}</th>
                <th class="py-1 text-left">{gettext("At")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={c <- @checkpoints}
                id={"checkpoint-#{c.last_seq}"}
                class="border-t border-base-300"
              >
                <td class="py-2 pr-3 font-mono text-meta">{c.first_seq} to {c.last_seq}</td>
                <td class="py-2 pr-3 text-meta">{c.reason}</td>
                <td class="py-2 pr-3 font-mono text-meta" title={c.tail_hash}>
                  {String.slice(c.tail_hash, 0, 16)}
                </td>
                <td class="py-2 font-mono text-meta">{stamp(c.inserted_at)}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :kind, :string, required: true

  defp kind_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-pill px-2 py-0.5 text-meta",
      @kind == "effect" && "bg-warning/20 text-warning",
      @kind == "decision" && "bg-info/20 text-info",
      @kind == "query" && "bg-base-300",
      @kind in ["boot", "cap"] && "bg-success/20 text-success"
    ]}>
      {@kind}
    </span>
    """
  end

  attr :outcome, :any, required: true

  defp outcome(assigns) do
    ~H"""
    <span
      id="verify-outcome"
      class={[
        "rounded-pill px-2 py-0.5 text-meta",
        match?({:ok, _}, @outcome) && "bg-success/20 text-success",
        match?({:error, _, _}, @outcome) && "bg-error/20 text-error"
      ]}
    >
      {describe(@outcome)}
    </span>
    """
  end

  defp describe({:ok, %{receipts: n, checkpoints: c}}),
    do: gettext("verified: %{n} receipts, %{c} checkpoints, exit 0", n: n, c: c)

  defp describe({:error, code, reason}),
    do: gettext("exit %{code}: %{reason}", code: code, reason: inspect(reason))

  defp subject(%{subject: s}) do
    [s["tool"], s["call_id"] && "call " <> s["call_id"], s["phase"], s["authority"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp decision(%{signed_payload: p}) do
    case JSON.decode(p) do
      {:ok, %{"decision" => d}} when is_map(d) ->
        d |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{value(v)}" end)

      _ ->
        ""
    end
  end

  defp value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: to_string(v)
  defp value(v), do: Jason.encode!(v)

  defp stamp(nil), do: ""
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S") <> " UTC"
end
