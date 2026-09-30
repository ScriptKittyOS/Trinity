# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ProfileSignerDownTest do
  @moduledoc """
  AC4, and the one thing this work was told not to change: the default profile still boots with the
  signer down, and `:regulated` does not.

  **`async: false`, and the reason is not politeness.** `Trinity.Receipts.KeyCustody.boot!/1` writes
  its answer to `:persistent_term` on both paths, including `{:unavailable, reason}` on failure. An
  earlier version of this ran inside an async file and poisoned the signer for the whole run: 48
  unrelated tests failed with `{:signer_unavailable, {:key_file, :enotdir}}`. ExUnit runs
  synchronous modules only after every async one has finished, so this is the only safe place to
  induce a real failure, and the selection is restored afterwards whatever happens.
  """
  use ExUnit.Case, async: false

  alias Trinity.Profile
  alias Trinity.Receipts.KeyCustody

  setup do
    # A path whose parent is a file, so the key store cannot be created. This is a real failure
    # from the real function rather than a hand-written error tuple.
    path = Path.join(System.tmp_dir!(), "profile-signer-#{System.unique_integer([:positive])}")
    File.write!(path, "a file where a directory should be")

    on_exit(fn ->
      # Put the real signer back before anything else runs. boot!/0 re-selects from the configured
      # keys directory and rewrites the persistent term.
      {:ok, _} = KeyCustody.boot!()
      File.rm(path)
    end)

    down = KeyCustody.boot!(Path.join(path, "keys"))

    assert {:error, _} = down,
           "the probe did not produce a failing boot!, so nothing below is testing what it claims"

    {:ok, signer_down: down}
  end

  test "the DEFAULT profile still boots with the signer down", %{signer_down: down} do
    assert :ok = Profile.check_receipts(:default, down),
           "the default profile refused a boot because the signer was unavailable. " <>
             "Trinity.Receipts.Supervisor is fail-open for every profile that is not :regulated, " <>
             "and making it fail closed for everyone is the one change this work was told not to " <>
             "make."
  end

  test "the REGULATED profile does not boot with the signer down, and says why", %{
    signer_down: down
  } do
    assert {:error, {:regulated_requires_receipts, {:key_file, :enotdir}}} =
             Profile.check_receipts(:regulated, down)
  end

  test "regulated boots when the signer is available" do
    assert :ok = Profile.check_receipts(:regulated, {:ok, %{algorithm: :ed25519}})
  end
end
