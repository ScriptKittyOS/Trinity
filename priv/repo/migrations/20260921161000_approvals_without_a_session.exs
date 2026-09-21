# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.ApprovalsWithoutASession do
  use Ecto.Migration

  # Slice 041: an approval may have no session (a staged skill change approved from the
  # page; a gateway's decision on `approvals:all`). Postgres drops the NOT NULL in place;
  # SQLite cannot alter a column, so the table is rebuilt with the same columns, foreign key
  # and indexes, the rows copied.
  def up do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres ->
        execute("ALTER TABLE approvals ALTER COLUMN session_id DROP NOT NULL")

      _ ->
        execute("""
        CREATE TABLE approvals_new (
          "id" TEXT PRIMARY KEY,
          "session_id" TEXT CONSTRAINT "approvals_session_id_fkey" REFERENCES "sessions"("id") ON DELETE CASCADE,
          "tool" TEXT NOT NULL,
          "args" TEXT DEFAULT ('{}') NOT NULL,
          "risk" TEXT NOT NULL,
          "fingerprint" TEXT NOT NULL,
          "status" TEXT DEFAULT 'pending' NOT NULL,
          "decision" TEXT,
          "decided_at" TEXT,
          "decided_by" TEXT,
          "consumed_at" TEXT,
          "expires_at" TEXT NOT NULL,
          "inserted_at" TEXT NOT NULL,
          "updated_at" TEXT NOT NULL
        )
        """)

        execute(
          "INSERT INTO approvals_new SELECT id, session_id, tool, args, risk, fingerprint, status, decision, decided_at, decided_by, consumed_at, expires_at, inserted_at, updated_at FROM approvals"
        )

        execute("DROP TABLE approvals")
        execute("ALTER TABLE approvals_new RENAME TO approvals")

        execute(
          "CREATE INDEX approvals_session_id_status_index ON approvals (session_id, status)"
        )

        execute(
          "CREATE INDEX approvals_status_expires_at_index ON approvals (status, expires_at)"
        )

        execute("CREATE INDEX approvals_fingerprint_index ON approvals (fingerprint)")
    end
  end

  def down do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres ->
        execute("ALTER TABLE approvals ALTER COLUMN session_id SET NOT NULL")

      _ ->
        :ok
    end
  end
end
