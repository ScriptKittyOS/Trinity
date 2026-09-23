# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Receipts do
  @moduledoc """
  What a gateway writes to the receipt chain (slice 070). One thing, for now: a decision that a
  channel was not allowed to make. docs/07 says a capped request is refused rather than dropped,
  and a refusal nobody can find afterwards is a drop with a message attached, so it is receipted
  on the session's own chain beside the decisions the gate writes there.

  The channel and the account that tried are named; nothing the person typed is copied, because
  the text of a message to a bot is not evidence about an approval.
  """

  alias Trinity.Gateways.{Adapter, Cap}
  alias Trinity.Permissions.Approval
  alias Trinity.Receipts

  require Logger

  @doc "Receipts a decision the channel's cap refused to make."
  @spec gateway_cap_refusal(Approval.t(), map()) :: :ok
  def gateway_cap_refusal(%Approval{} = approval, message) do
    adapter = Adapter.name(message.adapter)

    Receipts.append(Receipts.session_scope(approval.session_id), %{
      kind: "decision",
      subject: %{
        "phase" => "gateway_cap",
        "adapter" => adapter,
        "external_user_id" => message.external_user_id,
        "conversation" => message.conversation,
        "tool" => approval.tool,
        "risk" => approval.risk,
        "origin" => "gateway"
      },
      decision: %{
        "outcome" => "deny",
        "basis" => "channel_cap",
        "reason" => "#{approval.risk} is above this channel's ceiling #{Cap.ceiling(adapter)}"
      },
      subject_ref: "approval:" <> approval.id,
      meta: %{}
    })

    :ok
  rescue
    error -> Logger.warning("gateway: cap refusal not receipted: #{Exception.message(error)}")
  end
end
