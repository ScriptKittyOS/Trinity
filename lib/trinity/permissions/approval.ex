# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Approval do
  @moduledoc """
  A row of `approvals` (slice 021): one request for one call, with the fingerprint it binds,
  and its decision. The audit trail this slice owns: every decision has `decided_at` and
  `decided_by`; slice 024 reads these rows when it builds decision receipts and writes none
  of them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending allowed denied expired)
  @decisions ~w(once session always deny)

  @type t :: %__MODULE__{}

  schema "approvals" do
    field :tool, :string
    field :args, :map, default: %{}
    field :risk, :string
    field :fingerprint, :string
    field :status, :string, default: "pending"
    field :decision, :string
    field :decided_at, :utc_datetime_usec
    field :decided_by, :string
    field :consumed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    belongs_to :session, Trinity.Sessions.SessionRow
    timestamps()
  end

  @doc "The closed vocabularies."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @doc false
  @spec request_changeset(t(), map()) :: Ecto.Changeset.t()
  def request_changeset(approval, attrs) do
    approval
    |> cast(attrs, [:session_id, :tool, :args, :risk, :fingerprint, :expires_at])
    # Slice 041: a request may have no session (a staged skill change approved from the
    # page); its topic is `approvals:none` and `approvals:all`, its scope `session:none`.
    |> validate_required([:tool, :risk, :fingerprint, :expires_at])
    |> foreign_key_constraint(:session_id)
  end

  @doc false
  @spec decide_changeset(t(), map()) :: Ecto.Changeset.t()
  def decide_changeset(approval, attrs) do
    approval
    |> cast(attrs, [:status, :decision, :decided_at, :decided_by, :consumed_at])
    |> validate_required([:status, :decision, :decided_at, :decided_by])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:decision, @decisions)
  end
end
