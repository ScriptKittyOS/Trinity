# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.AddEmbeddingsToMemories do
  @moduledoc """
  Slice 032. A vector per semantic memory: `embedding` (float32 little-endian bytes, the
  brute-force store's column on SQLite), `embedding_model` and `embedding_dim` (which
  embedder made it; a store never mixes models). On Postgres, beside those, a pgvector
  column `embedding_vector` with an HNSW index over the semantic tier for the `Pgvector`
  store; the `vector` extension is created here (the CI image is pgvector's).
  """
  use Ecto.Migration

  def up do
    alter table(:memories) do
      add :embedding, :binary
      add :embedding_model, :string
      add :embedding_dim, :integer
    end

    create index(:memories, [:persona_id, :tier, :embedding_model])

    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute("CREATE EXTENSION IF NOT EXISTS vector")
      execute("ALTER TABLE memories ADD COLUMN embedding_vector vector(384)")

      execute(
        "CREATE INDEX memories_embedding_vector_idx ON memories USING hnsw (embedding_vector vector_cosine_ops) WHERE tier = 'semantic'"
      )
    end
  end

  def down do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute("DROP INDEX IF EXISTS memories_embedding_vector_idx")
      execute("ALTER TABLE memories DROP COLUMN IF EXISTS embedding_vector")
    end

    drop index(:memories, [:persona_id, :tier, :embedding_model])

    alter table(:memories) do
      remove :embedding
      remove :embedding_model
      remove :embedding_dim
    end
  end
end
