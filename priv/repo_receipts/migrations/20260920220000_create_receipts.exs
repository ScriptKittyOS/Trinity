# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Receipts.Migrations.CreateReceipts do
  @moduledoc """
  Slice 024. `receipts`, the per-scope hash chain (docs/05, ADR-0013), and
  `receipt_checkpoints`, the signed coverage blocks over query receipts (RFC 5848's shape:
  the boot they belong to, the first and last seq covered, the tail hash, the signature).

  `signed_payload` is the canonical text the signature covers, not a map: a verifier hashes
  the stored bytes and needs no canonicaliser of its own. Nothing here is ever updated or
  deleted; `receipt_checkpoints` exists so a checkpoint is a row, never a write onto a tail.
  """
  use Ecto.Migration

  def change do
    create table(:receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chain_scope, :string, null: false
      add :seq, :integer, null: false
      add :prev_hash, :string
      add :receipt_hash, :string, null: false
      add :scheme, :string, null: false
      add :kind, :string, null: false
      add :signed_payload, :text, null: false
      add :signature, :binary
      add :key_id, :string
      add :subject, :map, null: false, default: %{}
      add :subject_ref, :string
      add :meta, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:receipts, [:chain_scope, :seq])
    create unique_index(:receipts, [:receipt_hash])
    create index(:receipts, [:chain_scope, :kind])
    create index(:receipts, [:subject_ref])

    create table(:receipt_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chain_scope, :string, null: false
      add :boot_receipt_hash, :string
      add :first_seq, :integer, null: false
      add :last_seq, :integer, null: false
      add :tail_hash, :string, null: false
      add :scheme, :string, null: false
      add :signed_payload, :text, null: false
      add :signature, :binary, null: false
      add :key_id, :string, null: false
      add :reason, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:receipt_checkpoints, [:chain_scope, :last_seq])
  end
end
