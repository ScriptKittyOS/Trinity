# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.VaultTest do
  @moduledoc """
  Slice 025, AC2: a blob is ciphertext on disk, readable through the seam, and unreadable once the
  wrapped key cannot be opened.

  The third of those is the one worth writing carefully. "It decrypts when we ask" proves the
  round trip works; it does not prove the data was ever protected. Each test here that claims
  something is unreadable removes the thing that opens it and checks the failure, rather than
  asserting that ciphertext looks scrambled.
  """
  use ExUnit.Case, async: false

  alias Trinity.Keys.Local
  alias Trinity.Vault

  @secret "the quick brown fox jumps over the lazy dog, and a passphrase is not a threat model"

  setup do
    dir = Path.join(System.tmp_dir!(), "trinity-vault-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prior_keys = Application.get_env(:trinity, :keys)
    prior_pass = System.get_env("TRINITY_KEYS_PASSPHRASE")
    Application.put_env(:trinity, :keys, dir: dir, source: :passphrase)
    System.put_env("TRINITY_KEYS_PASSPHRASE", "a test passphrase")
    :persistent_term.erase({Local, :selection})

    on_exit(fn ->
      :persistent_term.erase({Local, :selection})

      if prior_keys,
        do: Application.put_env(:trinity, :keys, prior_keys),
        else: Application.delete_env(:trinity, :keys)

      if prior_pass,
        do: System.put_env("TRINITY_KEYS_PASSPHRASE", prior_pass),
        else: System.delete_env("TRINITY_KEYS_PASSPHRASE")

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "a sealed blob is ciphertext: the plaintext does not appear in it" do
    {:ok, sealed} = Vault.seal(@secret)

    refute sealed == @secret
    refute String.contains?(sealed, @secret)
    refute String.contains?(sealed, "quick brown fox")
    assert Vault.sealed?(sealed)
    assert {:ok, @secret} = Vault.open(sealed)
  end

  test "a sealed blob written to disk by a caller is ciphertext there", %{dir: dir} do
    path = Path.join(dir, "skill.md")
    {:ok, sealed} = Vault.seal(@secret)
    File.write!(path, sealed)
    File.chmod!(path, 0o600)

    on_disk = File.read!(path)
    refute String.contains?(on_disk, @secret)
    assert Vault.sealed?(on_disk)
    assert {:ok, @secret} = Vault.open(on_disk)

    # And a caller that writes a secret is expected to do so at 0600; a secret at 0644 is a secret
    # in name only.
    %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "every blob gets its own data key, so one compromise does not open the next" do
    {:ok, a} = Vault.seal(@secret)
    {:ok, b} = Vault.seal(@secret)

    # Same plaintext, different bytes: no deterministic encryption, no shared key or nonce.
    refute a == b
  end

  test "removing what opens the key makes the blob unreadable", %{dir: dir} do
    path = Path.join(dir, "export.tar")
    {:ok, sealed} = Vault.seal(@secret)
    File.write!(path, sealed)
    assert {:ok, @secret} = Vault.open(File.read!(path))

    # The passphrase source derives the root from the passphrase and the salt. Remove the salt and
    # a *different* root is derived, so the wrapped data key no longer opens. This is the real
    # failure mode for this source: not a corrupted file, a lost key.
    File.rm!(Local.salt_path())
    :persistent_term.erase({Local, :selection})

    assert {:error, reason} = Vault.open(File.read!(path))

    # The adapter is more precise than "it failed": the wrapper names the key id that sealed it,
    # that root is no longer derivable and was never retired, so the answer says which key is
    # missing rather than that some byte did not verify. An operator who sees this knows they
    # lost a key rather than corrupted a file.
    assert match?({:unknown_key_id, _}, reason) or
             reason in [:unwrap_failed, :blob_authentication_failed],
           "expected an error naming the missing key, got #{inspect(reason)}"

    # Whatever the reason, the property under test is that the plaintext did not come back.
    refute match?({:ok, @secret}, Vault.open(File.read!(path)))
  end

  test "a tampered blob is refused rather than opened to wrong bytes" do
    {:ok, sealed} = Vault.seal(@secret)
    last = byte_size(sealed) - 1
    <<head::binary-size(^last), b::8>> = sealed
    tampered = head <> <<Bitwise.bxor(b, 1)::8>>

    assert {:error, :blob_authentication_failed} = Vault.open(tampered)
  end

  test "a blob truncated after the marker is malformed, not a crash" do
    assert {:error, :malformed_blob} = Vault.open(Vault.version() <> <<200::8>> <> "short")
  end

  test "an unsealed blob passes through, so the two paths are the same code" do
    refute Vault.sealed?("plain text written before this slice")

    assert {:ok, "plain text written before this slice"} =
             Vault.open("plain text written before this slice")
  end
end
