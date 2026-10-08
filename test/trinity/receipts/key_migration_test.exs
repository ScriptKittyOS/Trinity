# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.KeyMigrationTest do
  @moduledoc """
  Slice 100, AC6: the receipt signing key leaves its file for the keychain, by rotation (NOTES
  D3). Receipts signed before the move still verify after it, the retired `key_id` carries a
  `valid_until`, the chain is one chain across the boundary, and nothing is re-keyed silently or
  partially: a keychain that cannot hold the key leaves the file-backed key in force and the
  registry untouched.

  The keychain is `Trinity.FakeKeychain`. The registry rows, the chain and the verifier are the
  real ones.
  """
  use Trinity.DataCase, async: false

  import ExUnit.CaptureLog

  alias Trinity.{FakeKeychain, Receipts}
  alias Trinity.Receipts.{KeyCustody, KeyRegistry, Verifier}

  setup do
    dir = Path.join(System.tmp_dir!(), "trinity-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old_env = Application.get_env(:trinity, :receipts, [])
    Application.put_env(:trinity, :receipts, Keyword.put(old_env, :keys_dir, dir))
    scope = "migration:" <> Trinity.UUID.generate()

    # Registered first, so it runs last: after FakeKeychain's own on_exit has removed the
    # helper, the suite's key is selected again from the suite's directory, file-backed.
    on_exit(fn ->
      Application.put_env(:trinity, :receipts, old_env)
      File.rm_rf!(dir)
      {:ok, _} = KeyCustody.boot!()
    end)

    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, dir: dir, scope: scope}
  end

  defp append!(scope, n) do
    for i <- 1..n do
      {:ok, _} =
        Receipts.append(scope, %{
          kind: "decision",
          subject: %{"i" => i},
          decision: %{"outcome" => "allow"},
          fingerprint: "f#{i}"
        })
    end
  end

  defp export!(scope) do
    :ok = Receipts.stop_writer(scope)
    {:ok, export} = Receipts.export(scope)
    export
  end

  test "AC6: receipts signed before the migration verify after it, across one unbroken chain",
       %{dir: dir, scope: scope} do
    {:ok, %{key_id: old_id, algorithm: alg}} = KeyCustody.boot!(dir)
    append!(scope, 5)

    _keychain = FakeKeychain.install!()

    log = capture_log(fn -> send(self(), KeyCustody.boot!(dir)) end)
    assert_received {:ok, %{key_id: new_id, custody: "keychain"}}
    refute new_id == old_id
    # Never silently: the log names both keys.
    assert log =~ old_id and log =~ new_id

    append!(scope, 5)
    export = export!(scope)

    ids = export["receipts"] |> Enum.sort_by(& &1["seq"]) |> Enum.map(& &1["key_id"])
    assert ids == List.duplicate(old_id, 5) ++ List.duplicate(new_id, 5)
    assert {:ok, %{receipts: 10}} = Verifier.verify(export, require_coverage: false)

    {:ok, rows} = KeyRegistry.read(dir)
    retired = KeyRegistry.lookup(rows, old_id)
    assert retired["status"] == "retired"
    assert {:ok, _, _} = DateTime.from_iso8601(retired["valid_until"])
    assert retired["superseded_by"] == new_id
    active = KeyRegistry.active_for(rows, alg)
    assert active["key_id"] == new_id
    assert active["custody"] == "keychain"
  end

  test "AC6: the registry only grew, the old private key was renamed rather than deleted, and the new one is not in a file",
       %{dir: dir} do
    {:ok, %{key_id: old_id, key_path: path}} = KeyCustody.boot!(dir)
    {:ok, before_rows} = KeyRegistry.read(dir)
    old_file = File.read!(path)

    keychain = FakeKeychain.install!()
    capture_log(fn -> {:ok, _} = KeyCustody.boot!(dir) end)

    {:ok, rows} = KeyRegistry.read(dir)
    assert Enum.take(rows, length(before_rows)) == before_rows
    assert length(rows) == length(before_rows) + 2

    [retired_file] = Path.wildcard(Path.join(dir, "receipts-*.retired-*.key"))
    assert File.read!(retired_file) == old_file
    assert File.stat!(retired_file).mode |> Bitwise.band(0o777) == 0o600

    {:ok, new_file} = path |> File.read!() |> JSON.decode()
    assert new_file["custody"] == "keychain"
    refute Map.has_key?(new_file, "private_b64")
    refute new_file["key_id"] == old_id

    # The private half is in the keychain (as the protocol's hex) and nowhere in the keys dir.
    assert [_entry] = File.ls!(Path.join(keychain, "store"))
  end

  test "AC6: a second boot with the keychain does not rotate again", %{dir: dir} do
    {:ok, _} = KeyCustody.boot!(dir)
    FakeKeychain.install!()
    capture_log(fn -> send(self(), KeyCustody.boot!(dir)) end)
    assert_received {:ok, %{key_id: first}}
    {:ok, rows} = KeyRegistry.read(dir)

    assert {:ok, %{key_id: ^first}} = KeyCustody.boot!(dir)
    assert {:ok, ^rows} = KeyRegistry.read(dir)
  end

  test "AC6: a boot that stopped between the registry rows and the file swap is finished by the next boot",
       %{dir: dir} do
    {:ok, %{key_path: path}} = KeyCustody.boot!(dir)
    FakeKeychain.install!()
    capture_log(fn -> send(self(), KeyCustody.boot!(dir)) end)
    assert_received {:ok, %{key_id: new_id}}
    {:ok, rows} = KeyRegistry.read(dir)

    # The state a crash after the rows and before the swap leaves: the registry says the old key is
    # retired and the keychain key is active, and the key file is still the old one.
    [retired_file] = Path.wildcard(Path.join(dir, "receipts-*.retired-*.key"))
    File.cp!(retired_file, path)

    assert {:ok, %{key_id: ^new_id, custody: "keychain"}} = KeyCustody.boot!(dir)
    assert {:ok, ^rows} = KeyRegistry.read(dir)
    assert {:ok, _sig} = KeyCustody.sign("bytes")
  end

  test "AC6: a keychain that cannot be reached leaves the file-backed key in force and the registry untouched",
       %{dir: dir} do
    {:ok, %{key_id: old_id}} = KeyCustody.boot!(dir)
    {:ok, rows} = KeyRegistry.read(dir)
    keychain = FakeKeychain.install!()
    FakeKeychain.break!(keychain)

    capture_log(fn -> assert {:ok, %{key_id: ^old_id}} = KeyCustody.boot!(dir) end)
    assert {:ok, ^rows} = KeyRegistry.read(dir)
    assert {:ok, _sig} = KeyCustody.sign("bytes")
  end

  test "AC6: after the move the key is read from the keychain at every sign, as the file was",
       %{dir: dir} do
    {:ok, _} = KeyCustody.boot!(dir)
    keychain = FakeKeychain.install!()
    capture_log(fn -> {:ok, _} = KeyCustody.boot!(dir) end)
    assert {:ok, _sig} = KeyCustody.sign("bytes")

    FakeKeychain.break!(keychain)
    assert {:error, {:signer_unavailable, _}} = KeyCustody.sign("bytes")
  end

  test "the verifier refuses a retired key's receipt dated after its valid_until", %{
    dir: dir,
    scope: scope
  } do
    {:ok, %{key_id: old_id}} = KeyCustody.boot!(dir)
    append!(scope, 3)
    FakeKeychain.install!()
    capture_log(fn -> {:ok, _} = KeyCustody.boot!(dir) end)
    export = export!(scope)
    assert {:ok, _} = Verifier.verify(export, require_coverage: false)

    # The same export with the retirement moved before the first receipt: those receipts now
    # claim a time at which their key was no longer valid.
    backdated =
      update_in(export["registry"], fn rows ->
        Enum.map(rows, fn
          %{"key_id" => ^old_id, "status" => "retired"} = row ->
            Map.put(row, "valid_until", "2000-01-01T00:00:00Z")

          row ->
            row
        end)
      end)

    assert {:error, 1, {:key_retired, 1, ^old_id}} =
             Verifier.verify(backdated, require_coverage: false)
  end
end
