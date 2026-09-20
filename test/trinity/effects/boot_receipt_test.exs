# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects.BootReceiptTest do
  @moduledoc """
  Slice 024 AC6: the boot receipt carries `core_policy_hash`, and changing a policy module
  changes the hash. The receipt was written when this suite's application started; the
  first test reads it back. The second plants a module, hashes it, changes its body,
  recompiles it and hashes again: the digest is over object code, so a changed module is
  a changed hash and an unchanged one is not.
  """
  use Trinity.DataCase, async: false

  alias Trinity.{CorePolicy, Receipts}

  test "the boot receipt of this run: scope boot, signed, the authority, the signer and the policy hash" do
    assert %Receipts.Receipt{kind: "boot", chain_scope: "boot", signature: sig} =
             r = Receipts.boot_receipt()

    assert is_binary(sig)
    assert r.subject["authority"] == "Trinity.Authority.Local"
    assert r.subject["signer"]["algorithm"] == "ed25519"
    assert r.subject["signer"]["key_id"] == Receipts.KeyCustody.selected().key_id
    assert r.subject["fips"] == "not_supported"
    assert r.meta["core_policy_hash"] == CorePolicy.hash()
    assert r.meta["canonicalization_version"] == 1
    body = JSON.decode!(r.signed_payload)
    assert body["subject"]["authority"] == "Trinity.Authority.Local"
    # The policy hash is unsigned metadata, per the R21 default: not in the signed body.
    refute Map.has_key?(body, "core_policy_hash")
    assert Receipts.boot_hash() == r.receipt_hash

    {:ok, export} = Receipts.export("boot")
    assert {:ok, %{receipts: n}} = Receipts.Verifier.verify(export)
    assert n >= 1
  end

  test "the list covers the modules that decide" do
    for m <- [
          Trinity.Permissions.Policy.Layered,
          Trinity.Tools.Catalog,
          Trinity.Effects,
          Trinity.Authority.Local,
          Trinity.Receipts.KeyCustody
        ],
        do: assert(m in CorePolicy.modules())

    assert CorePolicy.hash() == CorePolicy.hash_of(CorePolicy.modules())
  end

  test "changing a policy module changes the hash; an unchanged one does not" do
    mod = :"Elixir.Trinity.PlantedPolicy#{System.unique_integer([:positive])}"

    compile = fn body ->
      {:module, ^mod, binary, _} = Module.create(mod, body, Macro.Env.location(__ENV__))
      # get_object_code/1 reads the loaded module's binary through the code path; a module
      # created in memory has none, so the test writes it where the code server looks.
      dir = Path.join(System.tmp_dir!(), "trinity-policy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{mod}.beam"), binary)
      :code.purge(mod)
      :code.delete(mod)
      true = Code.prepend_path(dir)
      {:module, ^mod} = :code.load_file(mod)
      dir
    end

    d1 = compile.(quote(do: def(decide, do: :allow)))
    h1 = CorePolicy.hash_of([mod])
    h1_again = CorePolicy.hash_of([mod])
    d2 = compile.(quote(do: def(decide, do: :deny)))
    h2 = CorePolicy.hash_of([mod])

    on_exit(fn ->
      File.rm_rf!(d1)
      File.rm_rf!(d2)
    end)

    assert h1 == h1_again
    assert h1 != h2
    assert String.length(h1) == 64
  end
end
