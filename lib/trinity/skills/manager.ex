# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Manager do
  @moduledoc """
  Decisions on staged changes (slice 041). `approve/2` asks the permission gate for a
  `skill_apply` approval naming the change's id and digest (a row and a broadcast on
  `approvals:all`, so a gateway sees it too), decides it as the party given, and promotes
  through `Trinity.Skills.Promotion.swap/3`; `reject/2` marks the row and removes the staged
  files. `auto/2` is the persona's auto-approval: `settings["skills"]["auto_approve"]` is
  `"off"` by default, `"low"` applies a change whose severity is `none` or `low` at once as
  `"auto"`; `medium` and `high` are never auto-approved, whatever a rule says (AC4).
  """

  alias Trinity.Permissions
  alias Trinity.Repo
  alias Trinity.Skills.{Change, Promotion, Staging}

  @doc "Approves and promotes a pending change; `opts`: `by:` (default `\"ui\"`), `comment:`, `session_id:`."
  @spec approve(Change.t(), keyword()) :: {:ok, Change.t()} | {:error, term()}
  def approve(%Change{status: "pending"} = change, opts \\ []) do
    by = Keyword.get(opts, :by, "ui")
    # The proposing session when there was one; a change approved from the page with none
    # requests on `approvals:none` (and `approvals:all`, where a gateway listens).
    session_id = Keyword.get(opts, :session_id) || change.proposed_by
    args = %{"change_id" => change.id, "digest" => change.digest, "skill" => change.skill_name}

    with {:ok, approval} <-
           Permissions.request_approval(session_id, Promotion.tool(), args, risk: :write),
         {:ok, _} <- Permissions.decide_request(approval.id, :once, by: by) do
      Promotion.swap(change, approval.id, by, Keyword.get(opts, :comment))
    end
  end

  @doc "Rejects a pending change: the row says who and why, the staged files go."
  @spec reject(Change.t(), keyword()) :: {:ok, Change.t()} | {:error, term()}
  def reject(%Change{status: "pending"} = change, opts \\ []) do
    :ok = Staging.discard(change)

    change
    |> Change.changeset(%{
      status: "rejected",
      decided_by: Keyword.get(opts, :by, "ui"),
      decided_at: DateTime.utc_now(),
      comment: Keyword.get(opts, :comment)
    })
    |> Repo.update()
  end

  @doc "The persona's auto-approval, applied to a fresh change when it qualifies; `{:ok, change}` either way."
  @spec auto(Change.t(), map() | nil) :: {:ok, Change.t()}
  def auto(%Change{status: "pending", severity: severity} = change, persona) do
    if auto_approve?(persona) and severity in ["none", "low"] do
      case approve(change, by: "auto") do
        {:ok, applied} -> {:ok, applied}
        {:error, _} -> {:ok, change}
      end
    else
      {:ok, change}
    end
  end

  @doc "True when the persona's settings allow auto-approval of low-severity changes."
  @spec auto_approve?(map() | nil) :: boolean()
  def auto_approve?(%{settings: %{"skills" => %{"auto_approve" => "low"}}}), do: true
  def auto_approve?(_), do: false
end
