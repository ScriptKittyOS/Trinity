# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Keys.SignerSeamTest do
  @moduledoc """
  Slice 025, AC3 and AC1: the receipt signing key is sealed by the custody seam before it reaches
  disk, opens again through it, and the boot receipt names which adapter and source held it.

  The retrofit's obligation runs both ways. A key written *before* this slice carries no custody
  field and holds its private bytes directly, and it must still open: a slice that made every
  existing installation unbootable in order to gain a property would not be an improvement. That
  case is tested here explicitly, by writing the old format.
  """
  use ExUnit.Case, async: false

  alias Trinity.Keys.Local
  alias Trinity.Receipts.{KeyCustody, KeyRegistry}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "trinity-signer-seam-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    prior_keys = Application.get_env(:trinity, :keys)
    prior_receipts = Application.get_env(:trinity, :receipts)
    prior_pass = System.get_env("TRINITY_KEYS_PASSPHRASE")

    Application.put_env(:trinity, :keys, dir: dir, source: :passphrase)
    Application.put_env(:trinity, :receipts, Keyword.put(prior_receipts || [], :keys_dir, dir))
    System.put_env("TRINITY_KEYS_PASSPHRASE", "a signer seam passphrase")
    :persistent_term.erase({Local, :selection})

    on_exit(fn ->
      :persistent_term.erase({Local, :selection})

      # KeyCustody.boot!/1 records its selection in :persistent_term, which outlives this test's
      # process and every sandbox. Without putting the real one back, every later test in the run
      # signs against a temporary directory this test has just deleted, and the failure surfaces
      # as `signer_unavailable` in tests that have nothing to do with keys. Restoring the config
      # is not enough: the selection has to be re-made from it.
      restore = fn ->
        if prior_receipts,
          do: Application.put_env(:trinity, :receipts, prior_receipts),
          else: Application.delete_env(:trinity, :receipts)

        KeyCustody.boot!()
      end

      if prior_keys,
        do: Application.put_env(:trinity, :keys, prior_keys),
        else: Application.delete_env(:trinity, :keys)

      if prior_pass,
        do: System.put_env("TRINITY_KEYS_PASSPHRASE", prior_pass),
        else: System.delete_env("TRINITY_KEYS_PASSPHRASE")

      restore.()
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "the signing key is ciphertext on disk and the registry says so", %{dir: dir} do
    assert {:ok, selection} = KeyCustody.boot!(dir)

    raw = File.read!(selection.key_path)
    {:ok, row} = JSON.decode(raw)

    assert row["custody"] == "sealed"

    # The stored private value is what the seam produced, not the key itself: it carries the
    # vault's wrapper marker, and the wrapper is longer than the key it holds.
    {:ok, stored} = Base.decode64(row["private_b64"])
    assert String.starts_with?(stored, "TKW1")

    # And the registry row records the custody that actually held it, rather than a constant.
    {:ok, rows} = KeyRegistry.read(dir)
    assert %{"custody" => "sealed"} = KeyRegistry.lookup(rows, selection.key_id)
  end

  test "a sealed key still signs, which is the point of sealing it", %{dir: dir} do
    assert {:ok, _selection} = KeyCustody.boot!(dir)
    assert {:ok, signature} = KeyCustody.sign("some pae bytes")
    assert is_binary(signature) and byte_size(signature) > 0
  end

  test "losing what opens the key makes the signer unavailable rather than silently wrong", %{
    dir: dir
  } do
    assert {:ok, _} = KeyCustody.boot!(dir)
    assert {:ok, _} = KeyCustody.sign("before")

    File.rm!(Local.salt_path())
    :persistent_term.erase({Local, :selection})

    assert {:error, _reason} = KeyCustody.sign("after")
  end

  test "a key file written before this slice still opens", %{dir: dir} do
    # Boot once to get a real keypair and registry row, then rewrite the file in the old shape:
    # no custody field, private bytes stored directly.
    assert {:ok, selection} = KeyCustody.boot!(dir)
    {:ok, row} = JSON.decode(File.read!(selection.key_path))
    {:ok, wrapped} = Base.decode64(row["private_b64"])
    {:ok, plain} = Trinity.Keys.unwrap(wrapped)

    old_format =
      row
      |> Map.delete("custody")
      |> Map.put("private_b64", Base.encode64(plain))
      |> JSON.encode!()

    File.write!(selection.key_path, old_format)

    assert {:ok, _} = KeyCustody.boot!(dir)
    assert {:ok, signature} = KeyCustody.sign("pae bytes from an old installation")
    assert is_binary(signature)
  end

  test "AC1: the boot receipt subject names the adapter, the source and no key material" do
    subject = Trinity.Effects.Boot.key_custody_subject()

    assert subject["adapter"] =~ "Trinity.Keys.Local"
    assert subject["source"] == "passphrase"
    assert is_binary(subject["key_id"])
    assert subject["detail"] =~ "PBKDF2"

    {:ok, material} = Trinity.Keys.fetch(:receipts)
    refute String.contains?(JSON.encode!(subject), Base.encode64(material))
  end
end
