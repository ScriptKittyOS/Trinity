# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ApprovalComponents do
  @moduledoc """
  The approval card and its neighbours. Slice 021, in the vocabulary slice 013 decided.

  A card shows the tool, its risk as a badge, the arguments pretty-printed, a plain sentence
  about what `:exec` and `:destructive` mean, and four buttons. The buttons push events the
  page turns into `Trinity.Permissions.decide_request/3`; nothing on the card carries authority
  of its own (M7). "Always allow" shows the pattern that would be written, pre-filled from the
  arguments and editable, so what is granted is what the person read.
  """
  use Phoenix.Component
  use Gettext, backend: TrinityWeb.Gettext

  import TrinityWeb.CoreComponents, only: [icon: 1]

  alias Trinity.Permissions.Approval

  @doc "One pending request."
  attr :approval, Approval, required: true

  attr :pattern, :string,
    default: nil,
    doc: "the always-allow pattern as edited; the suggestion by default"

  def approval_card(assigns) do
    assigns = assign(assigns, :pattern, assigns.pattern || suggest_pattern(assigns.approval))

    ~H"""
    <div
      id={"approval-#{@approval.id}"}
      class="flex flex-col gap-3 rounded-panel border border-warning/50 bg-warning/10 px-4 py-3 text-ui"
      role="dialog"
      aria-label={gettext("Approval requested")}
    >
      <div class="flex flex-wrap items-center gap-2">
        <.icon name="hero-hand-raised-micro" class="size-5 text-warning" />
        <span class="font-semibold">{gettext("Trinity wants to run")}</span>
        <span class="font-mono">{@approval.tool}</span>
        <.risk_badge risk={@approval.risk} />
      </div>
      <pre
        class="max-h-48 overflow-auto rounded-field bg-base-100 px-3 py-2 font-mono text-sm"
        phx-no-format
      >{Jason.encode!(@approval.args, pretty: true)}</pre>
      <p :if={@approval.risk in ["exec", "destructive"]} class="text-error">
        {danger(@approval.risk)}
      </p>
      <form
        id={"always-#{@approval.id}"}
        phx-change="approval_pattern"
        phx-value-id={@approval.id}
        class="flex items-center gap-2 text-meta"
      >
        <label for={"pattern-#{@approval.id}"} class="opacity-70">{gettext("Always allow when")}</label>
        <input type="hidden" name="approval_id" value={@approval.id} />
        <input
          id={"pattern-#{@approval.id}"}
          name="pattern"
          value={@pattern}
          class="min-w-0 flex-1 rounded-field border border-base-300 bg-base-100 px-2 py-1 font-mono"
        />
      </form>
      <div class="flex flex-wrap gap-2">
        <.decision_button id={@approval.id} decision="once" label={gettext("Allow once")} primary />
        <.decision_button
          id={@approval.id}
          decision="session"
          label={gettext("Allow for this session")}
        />
        <.decision_button id={@approval.id} decision="always" label={gettext("Always allow")} />
        <.decision_button id={@approval.id} decision="deny" label={gettext("Deny")} danger />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :decision, :string, required: true
  attr :label, :string, required: true
  attr :primary, :boolean, default: false
  attr :danger, :boolean, default: false

  defp decision_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="approval_decide"
      phx-value-id={@id}
      phx-value-decision={@decision}
      class={[
        "cursor-pointer rounded-field border px-3 py-1.5 text-ui transition",
        @primary && "border-primary bg-primary text-primary-content hover:brightness-110",
        @danger && "border-error/50 text-error hover:bg-error/10",
        (not @primary and not @danger) && "border-base-300 bg-base-100 hover:border-primary"
      ]}
    >
      {@label}
    </button>
    """
  end

  @doc "The risk tier as a badge."
  attr :risk, :string, required: true

  def risk_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-pill px-2 py-0.5 text-meta font-semibold uppercase tracking-wide",
      @risk in ["read", "network"] && "bg-info/20 text-info",
      @risk == "write" && "bg-warning/20 text-warning",
      @risk in ["exec", "destructive"] && "bg-error/20 text-error",
      @risk == "ask" && "bg-base-300"
    ]}>
      {@risk}
    </span>
    """
  end

  @doc "The header's pending indicator: nothing, or a count linking to the audit page."
  attr :count, :integer, required: true

  def pending_indicator(assigns) do
    ~H"""
    <.link
      :if={@count > 0}
      id="pending-approvals"
      navigate="/permissions"
      class="flex items-center gap-1 rounded-pill bg-warning/20 px-2 py-0.5 text-meta text-warning"
      title={gettext("Approvals waiting")}
    >
      <.icon name="hero-hand-raised-micro" class="size-4" /> {@count}
    </.link>
    """
  end

  @doc "The pattern proposed for always-allow: the first path-like argument as a glob on its directory, else `*`."
  @spec suggest_pattern(Approval.t()) :: String.t()
  def suggest_pattern(%Approval{args: args}) do
    case Enum.find(args, fn {_k, v} -> is_binary(v) and String.starts_with?(v, "/") end) do
      {key, path} -> "#{key}=#{Path.dirname(path)}/*"
      nil -> "*"
    end
  end

  defp danger("exec"),
    do:
      gettext("This runs a program on your machine. Approve only if you understand the command.")

  defp danger("destructive"),
    do: gettext("This can delete or overwrite data. Approve only if you meant it.")

  defp danger(_), do: ""
end
