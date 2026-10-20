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
    selected = Receipts.KeyCustody.selected()
    assert r.subject["signer"]["algorithm"] == Atom.to_string(selected.algorithm)
    assert r.subject["signer"]["key_id"] == selected.key_id
    assert r.subject["fips"] == Atom.to_string(:crypto.info_fips())
    assert r.meta["core_policy_hash"] == CorePolicy.hash()
    assert r.meta["canonicalization_version"] == 1
    body = Trinity.TestSupport.ReceiptBody.of(r)
    assert body["subject"]["authority"] == "Trinity.Authority.Local"
    # The policy hash is unsigned metadata, per the R21 default: not in the signed body.
    refute Map.has_key?(body, "core_policy_hash")
    assert Receipts.boot_hash() == r.receipt_hash

    {:ok, export} = Receipts.export("boot")
    assert {:ok, %{receipts: n}} = Receipts.Verifier.verify(export)
    assert n >= 1
  end

  # Slice 137 AC8: the runtime the floor was checked against, and the ML-DSA-87 known-answer
  # check's answer at this boot, are in the signed subject, and the chain still verifies.
  test "the boot receipt records erts, Elixir and the ML-DSA-87 check, signed" do
    r = Receipts.boot_receipt()
    %{erts: erts, elixir: elixir} = Trinity.Toolchain.current()

    want =
      case Trinity.Crypto.Preflight.mldsa87() do
        :ok -> "ok"
        {:error, {:mldsa87_preflight_failed, step, _}} -> "failed:#{step}"
      end

    body = Trinity.TestSupport.ReceiptBody.of(r)

    for {key, value} <- [{"erts", erts}, {"elixir", elixir}, {"mldsa87_preflight", want}] do
      assert r.subject[key] == value, key
      assert body["subject"][key] == value, "#{key} is not in the signed body"
    end

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
      # Not "trinity-<anything>": :code.lib_dir/1 reads a code-path entry named like
      # `<app>-<vsn>` as the application's directory, and a prepended "trinity-policy-N"
      # made Application.app_dir(:trinity) point at /tmp for every later test (slice 034
      # found it: the migration files vanished). The path is removed on exit as well.
      dir = Path.join(System.tmp_dir!(), "planted-policy-#{System.unique_integer([:positive])}")
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
      Code.delete_path(d1)
      Code.delete_path(d2)
      File.rm_rf!(d1)
      File.rm_rf!(d2)
    end)

    assert h1 == h1_again
    assert h1 != h2
    assert String.length(h1) == 64
  end
end
