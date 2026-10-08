# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateMemoryEmbeddings do
  @moduledoc """
  Slice 133, AC1. Vectors move out of `memories` into `memory_embeddings`, keyed
  `(memory_id, space_id)`, and every space a row belongs to is an `embedding_spaces` row holding
  its fourteen-field manifest (`Trinity.Memory.Space`).

  Why a table and not columns: a memory can hold a vector in two spaces at once, which is what a
  re-tier needs (the new space is built beside the old one, and the old one stays until the
  operator drops it). And on Postgres `memories.embedding_vector vector(384)` cannot hold a 256-wide
  vector beside a 384-wide one, so the column here is an **untyped** `vector`, with one partial
  expression HNSW index per space (`(embedding_vector::vector(<dim>))`, `WHERE space_id = '<id>'`).

  The move: each distinct `(embedding_model, embedding_dim)` in `memories` becomes a legacy space
  (every field the row never recorded is `"unrecorded"`; `legacy_manifest/2` is a frozen copy of
  `Trinity.Memory.Space.legacy/2`, held equal to it by a test), every row with a vector is copied
  under its space with its bytes unchanged (float32, as they were written), and the space of the
  most recently embedded row is the store's active space (NOTES, decision 3). Then the old columns
  and their indexes go. `down/0` puts the active space's vectors back on the rows.
  """
  use Ecto.Migration

  def up do
    create table(:embedding_spaces, primary_key: false) do
      add :id, :string, primary_key: true
      add :manifest, :map, null: false
      add :dim, :integer, null: false
      add :quantization, :string, null: false
      add :state, :string, null: false, default: "complete"
      add :active, :boolean, null: false, default: false
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # One active space per store, held by the database: a second `active = true` row is refused.
    create unique_index(:embedding_spaces, [:active],
             where: "active",
             name: :embedding_spaces_one_active
           )

    create table(:memory_embeddings, primary_key: false) do
      add :memory_id, references(:memories, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :space_id, references(:embedding_spaces, type: :string, on_delete: :restrict),
        primary_key: true,
        null: false

      add :dim, :integer, null: false
      add :vector, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:memory_embeddings, [:space_id])

    if postgres?() do
      execute("ALTER TABLE memory_embeddings ADD COLUMN embedding_vector vector")
    end

    flush()
    move_rows()

    if postgres?() do
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

  def down do
    alter table(:memories) do
      add :embedding, :binary
      add :embedding_model, :string
      add :embedding_dim, :integer
    end

    create index(:memories, [:persona_id, :tier, :embedding_model])

    if postgres?() do
      execute("ALTER TABLE memories ADD COLUMN embedding_vector vector(384)")
    end

    flush()

    # The active space's vectors return to their rows, under the space's model id, which for a
    # legacy space is the `embedding_model` it came from. Other spaces' vectors have no column
    # to go back to and are dropped with the table.
    %{rows: active} =
      repo().query!("SELECT id, manifest FROM embedding_spaces WHERE active = #{true_literal()}")

    for [space_id, manifest] <- active do
      model = decode(manifest)["model_id"]

      repo().query!(
        "UPDATE memories SET embedding = (SELECT vector FROM memory_embeddings e WHERE e.memory_id = memories.id AND e.space_id = #{p(1)}), " <>
          "embedding_dim = (SELECT dim FROM memory_embeddings e WHERE e.memory_id = memories.id AND e.space_id = #{p(1)}), " <>
          "embedding_model = #{p(2)} " <>
          "WHERE id IN (SELECT memory_id FROM memory_embeddings WHERE space_id = #{p(1)})",
        [space_id, model]
      )

      if postgres?() do
        repo().query!(
          "UPDATE memories SET embedding_vector = (SELECT embedding_vector::vector(384) FROM memory_embeddings e WHERE e.memory_id = memories.id AND e.space_id = $1) " <>
            "WHERE embedding_dim = 384 AND id IN (SELECT memory_id FROM memory_embeddings WHERE space_id = $1)",
          [space_id]
        )
      end
    end

    if postgres?() do
      execute(
        "CREATE INDEX memories_embedding_vector_idx ON memories USING hnsw (embedding_vector vector_cosine_ops) WHERE tier = 'semantic'"
      )
    end

    drop table(:memory_embeddings)
    drop table(:embedding_spaces)
  end

  defp move_rows do
    %{rows: models} =
      repo().query!(
        "SELECT embedding_model, embedding_dim, MAX(updated_at) FROM memories " <>
          "WHERE embedding IS NOT NULL AND embedding_model IS NOT NULL AND embedding_dim IS NOT NULL " <>
          "GROUP BY embedding_model, embedding_dim"
      )

    now = DateTime.utc_now()

    spaces =
      for [model, dim, last] <- models do
        manifest = legacy_manifest(model, dim)
        id = manifest_id(manifest)

        repo().query!(
          "INSERT INTO embedding_spaces (id, manifest, dim, quantization, state, active, completed_at, inserted_at, updated_at) " <>
            "VALUES (#{p(1)}, #{p(2)}, #{p(3)}, 'f32', 'complete', #{false_literal()}, #{p(4)}, #{p(4)}, #{p(4)})",
          [id, encode(manifest), dim, now]
        )

        repo().query!(
          "INSERT INTO memory_embeddings (memory_id, space_id, dim, vector, inserted_at" <>
            if(postgres?(), do: ", embedding_vector", else: "") <>
            ") SELECT id, #{p(1)}, embedding_dim, embedding, #{p(2)}" <>
            if(postgres?(), do: ", embedding_vector::vector", else: "") <>
            " FROM memories WHERE embedding IS NOT NULL AND embedding_model = #{p(3)} AND embedding_dim = #{p(4)}",
          [id, now, model, dim]
        )

        if postgres?() and dim <= 2000 do
          fill_pg_vectors(id)
          create_space_index(id, dim)
        end

        {id, last}
      end

    case Enum.max_by(spaces, &elem(&1, 1), &later?/2, fn -> nil end) do
      nil ->
        :ok

      {id, _} ->
        repo().query!(
          "UPDATE embedding_spaces SET active = #{true_literal()} WHERE id = #{p(1)}",
          [id]
        )
    end
  end

  # Slice 032 filled `memories.embedding_vector` only for 384-wide vectors; a row of another
  # width under 2,000 has its bytes and no pgvector value. It gets one here, decoded from its
  # float32 bytes, so every row of an indexed space can be ranked by the index.
  defp fill_pg_vectors(id) do
    %{rows: rows} =
      repo().query!(
        "SELECT memory_id, vector FROM memory_embeddings WHERE space_id = $1 AND embedding_vector IS NULL",
        [id]
      )

    for [memory_id, bytes] <- rows do
      floats = for <<f::float-little-32 <- bytes>>, do: f

      repo().query!(
        "UPDATE memory_embeddings SET embedding_vector = $1 WHERE memory_id = $2 AND space_id = $3",
        [Pgvector.new(floats), memory_id, id]
      )
    end
  end

  defp later?(a, b), do: compare(a, b) != :lt

  defp compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)
  defp compare(a, b) when is_binary(a) and is_binary(b), do: if(a >= b, do: :gt, else: :lt)

  # The per-space index, the same statement `Trinity.Memory.Spaces` issues for a new space, and
  # serial for the same reason: a parallel HNSW build wants dynamic shared memory a container's
  # default /dev/shm does not have.
  defp create_space_index(id, dim) do
    true = id =~ ~r/\A[0-9a-f]{64}\z/
    repo().query!("SET LOCAL max_parallel_maintenance_workers = 0")

    repo().query!(
      "CREATE INDEX IF NOT EXISTS memory_embeddings_hnsw_#{binary_part(id, 0, 16)} ON memory_embeddings " <>
        "USING hnsw ((embedding_vector::vector(#{dim})) vector_cosine_ops) WHERE space_id = '#{id}'"
    )
  end

  # A frozen copy of `Trinity.Memory.Space.legacy/2` and `Space.id/1` as of slice 133: a migration
  # must keep meaning what it meant when it ran, whatever the module becomes later.
  defp legacy_manifest(model, dim) do
    u = "unrecorded"

    %{
      "model_id" => model,
      "revision" => u,
      "weights_digest" => u,
      "tokenizer_digest" => u,
      "dim" => dim,
      "pooling" => u,
      "normalisation" => u,
      "quantization" => "f32",
      "query_prompt" => u,
      "document_prompt" => u,
      "max_input" => %{"tokens" => u, "truncation" => u},
      "runtime" => %{"name" => u, "version" => u},
      "locality" => u,
      "num_ctx" => u
    }
  end

  defp manifest_id(manifest),
    do:
      manifest |> Jcs.encode() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp encode(manifest) do
    if postgres?(), do: manifest, else: Jason.encode!(manifest)
  end

  defp decode(m) when is_map(m), do: m
  defp decode(m) when is_binary(m), do: Jason.decode!(m)

  defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
  defp p(n), do: if(postgres?(), do: "$#{n}", else: "?#{n}")
  defp true_literal, do: if(postgres?(), do: "TRUE", else: "1")
  defp false_literal, do: if(postgres?(), do: "FALSE", else: "0")
end
