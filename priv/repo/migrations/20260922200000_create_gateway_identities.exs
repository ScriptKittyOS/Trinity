# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateGatewayIdentities do
  use Ecto.Migration

  # Slice 070 (docs/05, docs/07 "Gateways"): who outside this machine may talk to Trinity. One
  # row per (adapter, external user), unique on the pair: an id is only ever known within the
  # platform that issued it, so the adapter is half the key. `state` is "pending" (a code was
  # shown and not yet entered), "paired" (the owner proved it) or "revoked" (kept rather than
  # deleted, so a revoked id cannot silently re-pair itself without appearing here).
  def change do
    create table(:gateway_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :adapter, :string, null: false
      add :external_user_id, :string, null: false
      add :display_name, :string
      add :state, :string, null: false, default: "pending"
      add :code, :string
      add :code_expires_at, :utc_datetime_usec
      add :paired_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      # The conversation the pairing was asked from, so the answer goes back where it came from.
      add :last_conversation, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gateway_identities, [:adapter, :external_user_id])
    create index(:gateway_identities, [:state])
  end
end
