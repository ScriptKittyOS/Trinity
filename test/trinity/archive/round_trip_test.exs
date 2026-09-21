# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Archive.RoundTripTest do
  @moduledoc """
  Slice 034. AC1, AC2 and AC5 end to end on real files: the sandbox is switched to `:auto`
  for these tests (VACUUM cannot run inside the sandbox's transaction, and the rows must be
  on disk for the snapshot to carry them), the rows are made through the contexts, exported,
  imported into an empty directory, and read back through dynamic repos on the restored files.
  AC3, AC4 and AC6 work on the archive and the target directory alone.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Trinity.{Archive, Receipts, Sessions}
  alias Trinity.Archive.{Layout, Manifest}
  alias Trinity.Memory.AlwaysOn

  setup do
    Sandbox.mode(Trinity.Repo, :auto)
    Sandbox.mode(Trinity.Repo.Receipts, :auto)
    tmp = Path.join(System.tmp_dir!(), "trinity-archive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      Sandbox.mode(Trinity.Repo, :manual)
      Sandbox.mode(Trinity.Repo.Receipts, :manual)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, source: Layout.current()}
  end

  # A persona with a session, messages, memories and a receipt chain, all committed; the
  # cleanup deletes the persona (cascading the rest) and the receipts.
  defp seed do
    {:ok, persona} =
      Sessions.create_persona(%{
        name: "archive-#{System.unique_integer([:positive])}",
        soul: "# Archived"
      })

    {:ok, session} =
      Sessions.create_session(%{
        persona_id: persona.id,
        origin: "desktop",
        title: "To be archived"
      })

    for i <- 1..5,
        do:
          {:ok, _} =
            Sessions.append_message(session.id, %{
              role: "user",
              content: "message #{i} about widgets"
            })

    {:ok, _} =
      AlwaysOn.add(
        %{
          persona_id: persona.id,
          tier: "always_on",
          scope: AlwaysOn.persona_scope(persona.id),
          key: "editor",
          body: "neovim"
        }, by: "test")

    scope = Receipts.session_scope(session.id)

    for i <- 1..6,
        do:
          {:ok, _} =
            Receipts.append(scope, %{
              kind: if(rem(i, 2) == 0, do: "decision", else: "query"),
              subject: %{"i" => i},
              decision: %{"outcome" => "allow"}
            })

    :ok = Receipts.stop_writer(scope)
    %{persona: persona, session: session, scope: scope}
  end

  defp unseed(%{persona: persona, session: session, scope: scope}) do
    Trinity.Repo.delete_all(
      from(m in Trinity.Sessions.Message, where: m.session_id == ^session.id)
    )

    Trinity.Repo.delete_all(from(e in Trinity.Memory.Entry, where: e.persona_id == ^persona.id))
    Trinity.Repo.delete_all(from(c in Trinity.Memory.Change, where: c.persona_id == ^persona.id))
    Trinity.Repo.delete_all(from(s in Trinity.Sessions.SessionRow, where: s.id == ^session.id))
    Trinity.Repo.delete_all(from(p in Trinity.Sessions.Persona, where: p.id == ^persona.id))
    Trinity.Repo.Receipts.delete_all(from(r in Receipts.Receipt, where: r.chain_scope == ^scope))

    Trinity.Repo.Receipts.delete_all(
      from(c in Receipts.Checkpoint, where: c.chain_scope == ^scope)
    )
  end

  # Opens the restored databases as dynamic repos for the duration of `fun`.
  defp on_restored(%Layout{} = layout, fun) do
    {:ok, db} = Trinity.Repo.start_link(name: :restored_db, database: layout.db, pool_size: 1)

    {:ok, rdb} =
      Trinity.Repo.Receipts.start_link(
        name: :restored_receipts,
        database: layout.receipts_db,
        pool_size: 1
      )

    Trinity.Repo.put_dynamic_repo(:restored_db)
    Trinity.Repo.Receipts.put_dynamic_repo(:restored_receipts)

    try do
      fun.()
    after
      Trinity.Repo.put_dynamic_repo(Trinity.Repo)
      Trinity.Repo.Receipts.put_dynamic_repo(Trinity.Repo.Receipts)
      GenServer.stop(db)
      GenServer.stop(rdb)
    end
  end

  test "AC1 and AC2: export, import into an empty directory, the rows and the chain come back, the tree's digests match the manifest",
       %{tmp: tmp, source: source} do
    seeded = seed()
    on_exit(fn -> unseed(seeded) end)
    archive = Path.join(tmp, "trinity.tar.gz")

    assert {:ok, %{manifest: %Manifest{} = manifest, bytes: bytes}} =
             Archive.export(source, archive)

    assert bytes > 0

    assert Enum.map(manifest.files, & &1["path"]) |> Enum.sort() == [
             "keys/registry.json",
             "receipts.db",
             "trinity.db"
           ]

    assert manifest.keys_included == false
    assert manifest.schema_versions["trinity.db"] == Archive.available_versions(Trinity.Repo)

    assert manifest.schema_versions["receipts.db"] ==
             Archive.available_versions(Trinity.Repo.Receipts)

    target = Layout.of(Path.join(tmp, "restored"))
    File.mkdir_p!(target.data_dir)
    assert {:ok, %{replaced: [], written: written}} = Archive.import(archive, target)
    assert length(written) == 3
    assert File.read!(Path.join(target.data_dir, "RESTORED")) =~ "restored from trinity.tar.gz"

    # The digest over the restored tree is the manifest's, file for file.
    tree = Archive.digest_tree(target, manifest)
    assert tree == Map.new(manifest.files, &{&1["path"], &1["sha256"]})

    on_restored(target, fn ->
      persona = Sessions.get_persona(seeded.persona.id)
      assert persona.soul == "# Archived"
      session = Sessions.get_session(seeded.session.id)
      assert session.title == "To be archived"

      assert Enum.map(Sessions.history(session.id), & &1.content) ==
               for(i <- 1..5, do: "message #{i} about widgets")

      assert [%{key: "editor", body: "neovim"}] = AlwaysOn.all(persona.id)

      # AC2: the chain, read from the restored file, verified with the restored registry.
      rows = Receipts.list(seeded.scope)
      assert length(rows) == 6
      {:ok, registry} = Receipts.KeyRegistry.read(target.keys_dir)

      export = %{
        "receipts" => Enum.map(rows, &Receipts.Receipt.to_export/1),
        "checkpoints" =>
          Enum.map(Receipts.checkpoints(seeded.scope), &Receipts.Checkpoint.to_export/1),
        "registry" => registry
      }

      assert {:ok, %{receipts: 6}} = Receipts.Verifier.verify(export)
    end)
  end

  test "AC5: private keys are absent from a default export and present with keys: true; the manifest records which",
       %{tmp: tmp, source: source} do
    assert {:ok, %{manifest: plain}} = Archive.export(source, Path.join(tmp, "plain.tar.gz"))
    refute plain.keys_included
    refute Enum.any?(plain.files, &String.match?(&1["path"], ~r/^keys\/receipts-.*\.key$/))
    assert Enum.any?(plain.files, &(&1["path"] == "keys/registry.json"))

    assert {:ok, %{manifest: with_keys}} =
             Archive.export(source, Path.join(tmp, "keys.tar.gz"), keys: true)

    assert with_keys.keys_included
    assert Enum.any?(with_keys.files, &String.match?(&1["path"], ~r/^keys\/receipts-.*\.key$/))

    {:ok, entries} =
      :erl_tar.extract(String.to_charlist(Path.join(tmp, "plain.tar.gz")), [:compressed, :memory])

    names = Enum.map(entries, fn {n, _} -> List.to_string(n) end)
    refute Enum.any?(names, &String.ends_with?(&1, ".key"))
    assert "manifest.json" in names

    # Restored with the keys, the key file has the mode the custody expects.
    target = Layout.of(Path.join(tmp, "with-keys"))
    File.mkdir_p!(target.data_dir)
    assert {:ok, _} = Archive.import(Path.join(tmp, "keys.tar.gz"), target)
    [key] = Path.wildcard(Path.join(target.keys_dir, "receipts-*.key"))
    assert File.stat!(key).mode |> Bitwise.band(0o777) == 0o600
  end

  test "AC3: a non-empty target refuses with what it found; forced, the result states what it replaced",
       %{tmp: tmp, source: source} do
    archive = Path.join(tmp, "a.tar.gz")
    {:ok, _} = Archive.export(source, archive)
    target = Layout.of(Path.join(tmp, "busy"))
    File.mkdir_p!(target.keys_dir)
    File.write!(target.db, "not a database")
    File.write!(Path.join(target.keys_dir, "registry.json"), "[]")

    assert {:error, {:not_empty, present}} = Archive.import(archive, target)
    assert Enum.sort(present) == Enum.sort([target.db, target.keys_dir])
    assert File.read!(target.db) == "not a database"

    assert {:ok, %{replaced: replaced}} = Archive.import(archive, target, force: true)
    assert Enum.sort(replaced) == Enum.sort([target.db, target.keys_dir])
    assert File.read!(target.db) != "not a database"
  end

  test "AC4: a tampered archive fails digest verification before anything is written", %{
    tmp: tmp,
    source: source
  } do
    archive = Path.join(tmp, "good.tar.gz")
    {:ok, _} = Archive.export(source, archive)
    {:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:compressed, :memory])

    tampered =
      Enum.map(entries, fn
        {~c"receipts.db", bin} -> {~c"receipts.db", flip(bin)}
        other -> other
      end)

    bad = Path.join(tmp, "bad.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(bad), Enum.map(tampered, fn {n, b} -> {n, b} end), [
        :compressed
      ])

    target = Layout.of(Path.join(tmp, "untouched"))
    File.mkdir_p!(target.data_dir)

    assert {:error, {:verification_failed, [{"receipts.db", :digest_mismatch}]}} =
             Archive.import(bad, target)

    assert File.ls!(target.data_dir) == []

    # A manifest that names a file the tarball lacks is refused the same way, before writing.
    missing = Enum.reject(entries, fn {n, _} -> n == ~c"receipts.db" end)
    lacking = Path.join(tmp, "lacking.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(lacking), missing, [:compressed])

    assert {:error, {:verification_failed, [{"receipts.db", :missing}]}} =
             Archive.import(lacking, target)

    assert File.ls!(target.data_dir) == []
  end

  test "AC6: an archive from a newer schema refuses to import with the versions named", %{
    tmp: tmp,
    source: source
  } do
    archive = Path.join(tmp, "newer.tar.gz")
    {:ok, %{manifest: manifest}} = Archive.export(source, archive)
    {:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:compressed, :memory])
    future = 20_991_231_000_000

    bumped = %{
      manifest
      | schema_versions: Map.update!(manifest.schema_versions, "trinity.db", &(&1 ++ [future]))
    }

    rewritten =
      Enum.map(entries, fn
        {~c"manifest.json", _} -> {~c"manifest.json", Manifest.encode(bumped)}
        other -> other
      end)

    newer = Path.join(tmp, "newer2.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(newer), rewritten, [:compressed])
    target = Layout.of(Path.join(tmp, "old-binary"))
    File.mkdir_p!(target.data_dir)

    assert {:error, {:schema_newer_than_binary, [{"trinity.db", [^future]}]}} =
             Archive.import(newer, target)

    assert File.ls!(target.data_dir) == []
  end

  test "a manifest round-trips through JSON; another format is refused" do
    m = Manifest.build([%{path: "x", bytes: 1, sha256: "ab"}], %{"trinity.db" => [1, 2]}, true)
    assert {:ok, ^m} = Manifest.decode(Manifest.encode(m))
    assert {:error, {:unknown_format, "other/9"}} = Manifest.decode(~s({"format":"other/9"}))
    assert {:error, :not_a_manifest} = Manifest.decode(~s({"x":1}))
  end

  defp flip(<<a::binary-size(100), b, rest::binary>>),
    do: <<a::binary, Bitwise.bxor(b, 255), rest::binary>>
end
