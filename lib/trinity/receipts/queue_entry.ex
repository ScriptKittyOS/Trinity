# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.QueueEntry do
  @moduledoc """
  One receipt awaiting acknowledgement by the authority adapter (slice 026).

  `envelope` is the exported receipt byte for byte and is never rebuilt at send time, so a retry
  hands the far side exactly the bytes that were signed. Only `status`, `acked_at`, `attempts` and
  `last_error` are ever written after insert; the envelope and the identity of the row are fixed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  schema "receipt_queue" do
    field :chain_scope, :string
    field :seq, :integer
    field :receipt_hash, :string
    field :kind, :string
    field :envelope, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :queued_at, :utc_datetime_usec
    field :acked_at, :utc_datetime_usec
  end

  @statuses ~w(pending acked)

  @doc "The two statuses an entry can hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :chain_scope,
      :seq,
      :receipt_hash,
      :kind,
      :envelope,
      :status,
      :attempts,
      :last_error,
      :queued_at,
      :acked_at
    ])
    |> validate_required([:chain_scope, :seq, :receipt_hash, :kind, :envelope, :queued_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:receipt_hash)
    |> unique_constraint([:chain_scope, :seq])
  end
end
