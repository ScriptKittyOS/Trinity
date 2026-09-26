# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Receipts.Migrations.CreateReceiptQueue do
  @moduledoc """
  Slice 026. The durable outbound queue: one row per receipt awaiting acknowledgement by the
  authority adapter, per chain scope.

  `envelope` is the exported receipt **byte for byte**. The external authority plane's maintainers
  answered the question this slice was blocked on by saying that store-and-forward does not change
  their side as long as the acknowledgement carries the envelope they signed, unmodified: their
  verifiers check the signature over those bytes offline, so a queue may wrap, delay or re-deliver
  an envelope and may never re-sign it or alter a leaf. Storing the bytes rather than rebuilding
  them at send time is what makes that true here rather than merely intended.

  Nothing in this table is ever rewritten except `status` and `acked_at`. The receipt itself lives
  in `receipts` and is never touched by the queue.
  """
  use Ecto.Migration

  def change do
    create table(:receipt_queue, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chain_scope, :string, null: false
      add :seq, :integer, null: false
      add :receipt_hash, :string, null: false
      add :kind, :string, null: false
      add :envelope, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :string
      add :queued_at, :utc_datetime_usec, null: false
      add :acked_at, :utc_datetime_usec
    end

    # One queue entry per receipt: a receipt cannot be queued twice, so a re-delivery is a resend
    # of the same row rather than a second row that an adapter would see as a second fact.
    create unique_index(:receipt_queue, [:receipt_hash])
    create unique_index(:receipt_queue, [:chain_scope, :seq])

    # The drain reads pending rows for a scope in seq order; the depth check counts them.
    create index(:receipt_queue, [:chain_scope, :status, :seq])
  end
end
