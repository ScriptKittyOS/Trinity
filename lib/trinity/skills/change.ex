# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Change do
  @moduledoc """
  One row of `skill_changes` (slice 041, docs/05): a staged change to a skill, proposed by the
  agent (or the learn flow), with its diff, rationale, the scanner's findings and severity,
  and, once decided, the approval that promoted it and the receipt the promotion wrote.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  @actions ~w(create patch write_file remove_file delete)
  @statuses ~w(pending approved rejected applied failed)
  @severities ~w(none low medium high)

  schema "skill_changes" do
    field :skill_name, :string
    field :action, :string
    field :source, :string, default: "user"
    field :change_dir, :string
    field :diff, :string, default: ""
    field :rationale, :string, default: ""
    field :destructive, :boolean, default: false
    field :digest, :string
    field :status, :string, default: "pending"
    field :severity, :string, default: "none"
    field :findings, :map, default: %{}
    field :proposed_by, Trinity.UUID
    field :approval_id, Trinity.UUID
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    field :comment, :string
    field :receipt_hash, :string
    field :applied_version, :integer
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The actions, statuses and severities."
  @spec actions() :: [String.t()]
  def actions, do: @actions
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc false
  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :skill_name,
      :action,
      :source,
      :change_dir,
      :diff,
      :rationale,
      :destructive,
      :digest,
      :status,
      :severity,
      :findings,
      :proposed_by,
      :approval_id,
      :decided_by,
      :decided_at,
      :comment,
      :receipt_hash,
      :applied_version
    ])
    |> validate_required([
      :skill_name,
      :action,
      :source,
      :change_dir,
      :digest,
      :status,
      :severity
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:severity, @severities)
  end
end
