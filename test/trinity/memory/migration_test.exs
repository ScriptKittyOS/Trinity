# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.MigrationTest do
  @moduledoc """
  Slice 133, AC1's storage half: the migration moves every `memories.embedding*` row into
  `memory_embeddings`, and the count before equals the count after.

  On a database of its own (a file under the temporary directory on SQLite, a database named for
  the run on Postgres), through a second instance of `Trinity.Repo` that is not the suite's
  sandboxed one: migrated to the version before slice 133, given rows the way slice 032 wrote
  them (two models, rows with and without vectors, rows in other tiers), migrated up, read, and
  migrated down again.
  """
  use ExUnit.Case, async: false

  alias Trinity.Memory.Space

  @before 20_260_924_120_000
  @this 20_261_008_120_000
  @minilm "bumblebee:sentence-transformers/all-MiniLM-L6-v2"
  @fake "fake:sha256-384"

  # The migrator compiles the migration files again for each run in this VM, which the suite's
  # own migration already loaded; the redefinition is expected, and its warning only noise.
  setup_all do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, previous) end)
  end

  setup do
    {repo_pid, config, drop} = start_repo!()
    on_exit(drop)
    Trinity.Repo.put_dynamic_repo(repo_pid)
    on_exit(fn -> Trinity.Repo.put_dynamic_repo(Trinity.Repo) end)
    {:ok, repo: repo_pid, config: config}
  end

  defp postgres?, do: Application.get_env(:trinity, :db_adapter) == Ecto.Adapters.Postgres

  defp start_repo! do
    base = Application.get_env(:trinity, Trinity.Repo) |> Keyword.drop([:pool, :name])
    name = "trinity_mig_#{System.unique_integer([:positive])}"

    config =
      case Keyword.get(base, :url) do
        url when is_binary(url) ->
          uri = URI.parse(url)
          [user, pass] = String.split(uri.userinfo, ":", parts: 2)

          base
          |> Keyword.delete(:url)
          |> Keyword.merge(
            username: user,
            password: pass,
            hostname: uri.host,
            port: uri.port,
            database: name
          )

        _ ->
          Keyword.put(base, :database, Path.join(System.tmp_dir!(), name <> ".db"))
      end

    :ok = Trinity.Repo.__adapter__().storage_up(config)

    # `url: nil` matters: the repo merges its application config under these options and then
    # lets a URL override the explicit keys, so the suite's DATABASE_URL would otherwise point
    # this instance back at the suite's own database.
    {:ok, pid} =
      Trinity.Repo.start_link(
        Keyword.merge(config,
          url: nil,
          name: nil,
          pool: DBConnection.ConnectionPool,
          pool_size: 2
        )
      )

    # Guard the guard: this instance is on its own database, never the suite's.
    %{rows: [[db]]} = database(pid)
    if db != expected_name(config), do: raise("the migration test's repo is on #{db}")

    # Unlinked, so the test process's exit does not take it down before `on_exit` stops it.
    Process.unlink(pid)

    drop = fn ->
      Supervisor.stop(pid)
      Trinity.Repo.__adapter__().storage_down(config)
    end

    {pid, config, drop}
  end

  defp database(pid) do
    sql =
      if Application.get_env(:trinity, :db_adapter) == Ecto.Adapters.Postgres,
        do: "SELECT current_database()",
        else: "SELECT file FROM pragma_database_list WHERE name = 'main'"

    Trinity.Repo.put_dynamic_repo(pid)
    result = Trinity.Repo.query!(sql, [])
    Trinity.Repo.put_dynamic_repo(Trinity.Repo)
    result
  end

  defp expected_name(config) do
    if Application.get_env(:trinity, :db_adapter) == Ecto.Adapters.Postgres,
      do: config[:database],
      else: Path.expand(config[:database])
  end

  defp migrate(pid, direction, to) do
    Ecto.Migrator.run(Trinity.Repo, Ecto.Migrator.migrations_path(Trinity.Repo), direction,
      to: to,
      dynamic_repo: pid,
      log: false
    )
  end

  # `?` placeholders, numbered for Postgres.
  defp q(sql, params) do
    sql =
      if postgres?() do
        {s, _} =
          Enum.reduce(String.split(sql, "?"), {"", 0}, fn
            part, {"", 0} -> {part, 0}
            part, {acc, n} -> {acc <> "$#{n + 1}" <> part, n + 1}
          end)

        s
      else
        sql
      end

    Trinity.Repo.query!(sql, params)
  end

  defp uuid(id), do: if(postgres?(), do: Ecto.UUID.dump!(id), else: id)

  defp vector(seed, dim), do: for(i <- 1..dim, do: :math.sin(seed * 1.7 + i))

  defp f32(v), do: for(x <- v, into: <<>>, do: <<x::float-little-32>>)

  # Slice 032's shape: a vector on the row, the model that made it, its width.
  defp legacy_row!(persona, i, tier, model, at) do
    id = Trinity.UUID.generate()
    bytes = if model, do: f32(vector(i, 384))

    q(
      "INSERT INTO memories (id, persona_id, tier, scope, key, body, embedding, embedding_model, embedding_dim, inserted_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        uuid(id),
        uuid(persona),
        tier,
        "persona:#{persona}",
        "k-#{i}",
        "body #{i}",
        bytes,
        model,
        if(model, do: 384),
        at,
        at
      ]
    )

    if postgres?() and model do
      q("UPDATE memories SET embedding_vector = ? WHERE id = ?", [
        Pgvector.new(vector(i, 384)),
        uuid(id)
      ])
    end

    {id, bytes}
  end

  defp ts(seconds) do
    t = DateTime.add(~U[2026-09-30 00:00:00.000000Z], seconds, :second)
    if postgres?(), do: DateTime.to_naive(t), else: DateTime.to_iso8601(t)
  end

  test "AC1: every memories.embedding row moves into memory_embeddings; the count before equals the count after",
       %{repo: pid} do
    migrate(pid, :up, @before)
    persona = Trinity.UUID.generate()

    q("INSERT INTO personas (id, name, inserted_at, updated_at) VALUES (?, ?, ?, ?)", [
      uuid(persona),
      "migrated",
      ts(0),
      ts(0)
    ])

    # 40 MiniLM rows written earlier, 25 fake rows written later, and rows with no vector.
    minilm = for i <- 1..40, do: legacy_row!(persona, i, "semantic", @minilm, ts(i))
    fake = for i <- 41..65, do: legacy_row!(persona, i, "semantic", @fake, ts(1_000 + i))
    for i <- 66..70, do: legacy_row!(persona, i, "semantic", nil, ts(i))
    for i <- 71..75, do: legacy_row!(persona, i, "always_on", nil, ts(i))

    %{rows: [[before]]} = q("SELECT count(*) FROM memories WHERE embedding IS NOT NULL", [])
    %{rows: [[memories_before]]} = q("SELECT count(*) FROM memories", [])
    assert before == 65

    migrate(pid, :up, @this)

    %{rows: [[after_count]]} = q("SELECT count(*) FROM memory_embeddings", [])
    %{rows: [[memories_after]]} = q("SELECT count(*) FROM memories", [])

    IO.puts(
      "\nAC1 migration: #{before} memories with a vector before, #{after_count} memory_embeddings rows after; memories #{memories_before} before, #{memories_after} after"
    )

    assert after_count == before
    assert memories_after == memories_before

    # Each row under its legacy space, its bytes unchanged.
    a = Space.id(Space.legacy(@minilm, 384))
    b = Space.id(Space.legacy(@fake, 384))

    for {rows, space} <- [{minilm, a}, {fake, b}], {id, bytes} <- rows do
      %{rows: [[stored, dim]]} =
        q("SELECT vector, dim FROM memory_embeddings WHERE memory_id = ? AND space_id = ?", [
          uuid(id),
          space
        ])

      assert stored == bytes and dim == 384
    end

    # Two spaces, the migration's manifests equal to Space.legacy/2's (the frozen copy holds),
    # and the active one is the space of the most recently written vectors.
    %{rows: spaces} = q("SELECT id, active FROM embedding_spaces ORDER BY id", [])
    assert Enum.sort(Enum.map(spaces, &hd/1)) == Enum.sort([a, b])
    active = Map.new(spaces, fn [id, flag] -> {id, flag in [true, 1]} end)
    assert active == %{a => false, b => true}

    # The old columns are gone.
    cols = columns("memories")
    refute "embedding" in cols or "embedding_model" in cols or "embedding_dim" in cols

    if postgres?() do
      %{rows: [[type]]} =
        q(
          "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'memory_embeddings'::regclass AND attname = 'embedding_vector'",
          []
        )

      assert type == "vector"

      %{rows: [[copied]]} =
        q("SELECT count(*) FROM memory_embeddings WHERE embedding_vector IS NOT NULL", [])

      assert copied == before

      %{rows: indexes} =
        q("SELECT indexname FROM pg_indexes WHERE tablename = 'memory_embeddings'", [])

      for space <- [a, b] do
        assert [Trinity.Memory.Spaces.index_name(space)] in indexes
      end
    end

    # Down: the active space's vectors return to their rows; the tables go.
    migrate(pid, :down, @before)
    %{rows: [[back]]} = q("SELECT count(*) FROM memories WHERE embedding IS NOT NULL", [])
    assert back == length(fake)

    %{rows: [[model]]} =
      q("SELECT DISTINCT embedding_model FROM memories WHERE embedding IS NOT NULL", [])

    assert model == @fake
    refute "memory_embeddings" in tables()
  end

  test "an empty store migrates to no space and no active pointer", %{repo: pid} do
    migrate(pid, :up, @this)
    assert %{rows: [[0]]} = q("SELECT count(*) FROM embedding_spaces", [])
    assert %{rows: [[0]]} = q("SELECT count(*) FROM memory_embeddings", [])
  end

  defp columns(table) do
    if postgres?() do
      q("SELECT column_name FROM information_schema.columns WHERE table_name = ?", [table]).rows
      |> List.flatten()
    else
      q("SELECT name FROM pragma_table_info(?)", [table]).rows |> List.flatten()
    end
  end

  defp tables do
    if postgres?() do
      q("SELECT tablename FROM pg_tables WHERE schemaname = 'public'", []).rows |> List.flatten()
    else
      q("SELECT name FROM sqlite_master WHERE type = 'table'", []).rows |> List.flatten()
    end
  end
end
