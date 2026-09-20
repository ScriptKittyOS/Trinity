# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateMessagesFts do
  @moduledoc """
  Slice 031. Full-text search over `messages`, kept in step by the database itself.

  SQLite: the `messages_fts` FTS5 virtual table (`content`, with `session_id` and `message_id`
  unindexed, porter stemming over unicode61) and three triggers on `messages`, then a backfill
  of the rows already present. Postgres: a generated `content_tsv` column (`to_tsvector('english',
  ...)`) with a GIN index, which cannot fall out of step because it is not stored separately.
  The index is rebuildable from `messages` (`mix trinity.search.reindex`); losing it costs a
  reindex, never the messages.
  """
  use Ecto.Migration

  def up do
    case repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> sqlite_up()
      Ecto.Adapters.Postgres -> postgres_up()
    end
  end

  def down do
    case repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> sqlite_down()
      Ecto.Adapters.Postgres -> postgres_down()
    end
  end

  defp sqlite_up do
    execute("""
    CREATE VIRTUAL TABLE messages_fts USING fts5(
      content,
      session_id UNINDEXED,
      message_id UNINDEXED,
      tokenize = 'porter unicode61'
    )
    """)

    execute("""
    CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content, session_id, message_id)
      VALUES (new.rowid, new.content, new.session_id, new.id);
    END
    """)

    execute("""
    CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
      DELETE FROM messages_fts WHERE rowid = old.rowid;
    END
    """)

    execute("""
    CREATE TRIGGER messages_fts_au AFTER UPDATE OF content ON messages BEGIN
      DELETE FROM messages_fts WHERE rowid = old.rowid;
      INSERT INTO messages_fts(rowid, content, session_id, message_id)
      VALUES (new.rowid, new.content, new.session_id, new.id);
    END
    """)

    execute("""
    INSERT INTO messages_fts(rowid, content, session_id, message_id)
    SELECT rowid, content, session_id, id FROM messages
    """)
  end

  defp sqlite_down do
    execute("DROP TRIGGER IF EXISTS messages_fts_ai")
    execute("DROP TRIGGER IF EXISTS messages_fts_ad")
    execute("DROP TRIGGER IF EXISTS messages_fts_au")
    execute("DROP TABLE IF EXISTS messages_fts")
  end

  defp postgres_up do
    execute("""
    ALTER TABLE messages ADD COLUMN content_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED
    """)

    execute("CREATE INDEX messages_content_tsv_idx ON messages USING GIN (content_tsv)")
  end

  defp postgres_down do
    execute("DROP INDEX IF EXISTS messages_content_tsv_idx")
    execute("ALTER TABLE messages DROP COLUMN IF EXISTS content_tsv")
  end
end
