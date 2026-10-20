# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Receipts.Migrations.ReceiptsV4Columns do
  @moduledoc """
  Slice 140. Receipts v4 are N6 statements (`Trinity.Receipts.V4`): each row keeps its body, its
  single-signer carrier when its kind is signed, and the exact bytes its two ForeignRefs name, as
  bytes, never as a re-serialising JSON column. Checkpoints keep their body and carrier.

  Every column is nullable: v2 and v3 rows have none of them and are never rewritten. A v4 row's
  `signed_payload` is the empty string, because the column is NOT NULL and SQLite cannot relax that
  in place.
  """
  use Ecto.Migration

  def change do
    alter table(:receipts) do
      add :body, :binary
      add :carrier, :binary
      add :subject_bytes, :binary
      add :decision_bytes, :binary
    end

    alter table(:receipt_checkpoints) do
      add :body, :binary
      add :carrier, :binary
    end
  end
end
