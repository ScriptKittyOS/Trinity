# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Keys.LocalTest do
  @moduledoc """
  Slice 025, AC1 and AC4: every source works where it is present and refuses **by name** where it
  is not, the selection is recorded, and a rotation keeps what the old key sealed readable.

  The absent cases are not simulated where the machine already supplies them. This tree was built
  on a host with a TPM device and without `tpm2-tools`, which is exactly the half-present case an
  operator hits and the one a mocked test would never produce.
  """
  use ExUnit.Case, async: false

  alias Trinity.Keys
  alias Trinity.Keys.Local

  @pass "correct horse battery staple"

  setup do
    dir = Path.join(System.tmp_dir!(), "trinity-keys-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prior_keys = Application.get_env(:trinity, :keys)
    prior_pass = System.get_env("TRINITY_KEYS_PASSPHRASE")
    Application.put_env(:trinity, :keys, dir: dir, source: :passphrase)
    System.put_env("TRINITY_KEYS_PASSPHRASE", @pass)
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

  describe "AC1: a source works when present and is refused by name when absent" do
    test "the order is availability ascending, and it is the module's own list" do
      assert Local.sources() == [:systemd_credential, :tpm, :passphrase]
    end

    test "passphrase: available when set, refused by name when not" do
      assert Local.available?(:passphrase) == :ok

      System.delete_env("TRINITY_KEYS_PASSPHRASE")

      assert {:unavailable, :passphrase, :no_passphrase_configured} =
               Local.available?(:passphrase)

      System.put_env("TRINITY_KEYS_PASSPHRASE", "")
      assert {:unavailable, :passphrase, :empty_passphrase} = Local.available?(:passphrase)
    end

    test "systemd credential: refused by name when the process is not run under systemd" do
      prior = System.get_env("CREDENTIALS_DIRECTORY")
      System.delete_env("CREDENTIALS_DIRECTORY")

      assert {:unavailable, :systemd_credential, :not_run_under_systemd} =
               Local.available?(:systemd_credential)

      # Run under systemd but without this credential supplied: a different reason, because it
      # sends an operator somewhere different.
      empty = Path.join(System.tmp_dir!(), "creds-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      System.put_env("CREDENTIALS_DIRECTORY", empty)

      assert {:unavailable, :systemd_credential, :credential_not_supplied} =
               Local.available?(:systemd_credential)

      File.rm_rf(empty)

      if prior,
        do: System.put_env("CREDENTIALS_DIRECTORY", prior),
        else: System.delete_env("CREDENTIALS_DIRECTORY")
    end

    test "tpm: the refusal names which half is missing, device or tooling" do
      # Not mocked. Whatever this machine has, the answer must distinguish the two halves, because
      # "TPM unavailable" tells an operator nothing about what to install.
      case Local.available?(:tpm) do
        :ok ->
          assert File.exists?("/dev/tpmrm0") or File.exists?("/dev/tpm0")
          assert System.find_executable("tpm2_create")

        {:unavailable, :tpm, reason} ->
          assert reason in [:device_absent, :tooling_absent]

          if reason == :tooling_absent do
            assert File.exists?("/dev/tpmrm0") or File.exists?("/dev/tpm0"),
                   "tooling_absent should only be reported when the device is present"
          end
      end
    end

    test "an unknown source is refused rather than treated as available" do
      assert {:unavailable, :nonesuch, :unknown_source} = Local.available?(:nonesuch)
    end

    test "with no source available at all, the error names every refusal, not the last one" do
      System.delete_env("TRINITY_KEYS_PASSPHRASE")
      prior = System.get_env("CREDENTIALS_DIRECTORY")
      System.delete_env("CREDENTIALS_DIRECTORY")
      Application.put_env(:trinity, :keys, dir: Local.keys_dir())

      assert {:error, {:no_key_source, refusals}} = Local.select()
      assert Enum.map(refusals, &elem(&1, 0)) == [:systemd_credential, :tpm, :passphrase]
      assert Enum.all?(refusals, fn {_source, reason} -> is_atom(reason) end)

      if prior, do: System.put_env("CREDENTIALS_DIRECTORY", prior)
    end

    test "describe names the adapter, the source and a key id, and carries no key material" do
      d = Keys.describe()
      assert d.adapter == Local
      assert d.source == :passphrase
      assert is_binary(d.key_id) and byte_size(d.key_id) == 16
      assert d.detail =~ "PBKDF2"

      {:ok, material} = Keys.fetch(:receipts)
      refute d.key_id =~ Base.encode64(material)
      refute String.contains?(inspect(d), Base.encode64(material))
    end
  end

  describe "keys and wrapping" do
    test "a named key is stable, and a different name gives different bytes" do
      {:ok, a1} = Keys.fetch(:receipts)
      {:ok, a2} = Keys.fetch(:receipts)
      {:ok, b} = Keys.fetch(:envelopes)

      assert a1 == a2
      assert byte_size(a1) == 32
      refute a1 == b
    end

    test "wrap then unwrap returns the material, and the wrapper is not the material" do
      material = :crypto.strong_rand_bytes(32)
      {:ok, wrapped} = Keys.wrap(material)

      refute wrapped == material
      refute String.contains?(wrapped, material)
      assert {:ok, ^material} = Keys.unwrap(wrapped)
    end

    test "a tampered wrapper is refused rather than returning wrong bytes" do
      {:ok, wrapped} = Keys.wrap(:crypto.strong_rand_bytes(32))
      head_size = byte_size(wrapped) - 1
      <<head::binary-size(^head_size), last::8>> = wrapped
      tampered = head <> <<Bitwise.bxor(last, 1)::8>>

      assert {:error, :unwrap_failed} = Keys.unwrap(tampered)
      assert {:error, :malformed_wrapper} = Keys.unwrap("not a wrapper at all")
    end
  end

  describe "AC4: rotation" do
    test "new material uses the new key, and what the old key sealed still opens" do
      old_secret = :crypto.strong_rand_bytes(32)
      {:ok, sealed_before} = Keys.wrap(old_secret)
      before = Keys.describe()

      assert {:ok, _} = Keys.rotate()
      now = Keys.describe()

      # The root actually changed.
      refute now.key_id == before.key_id

      # And the thing sealed by the old root still opens, which is the property a rotation that
      # silently lost data would fail.
      assert {:ok, ^old_secret} = Keys.unwrap(sealed_before)

      # New material is sealed under the new root.
      new_secret = :crypto.strong_rand_bytes(32)
      {:ok, sealed_after} = Keys.wrap(new_secret)
      assert {:ok, ^new_secret} = Keys.unwrap(sealed_after)
      refute sealed_after == sealed_before
    end
  end
end
