# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.VerdictsTest do
  # Slice 144: the receipt verifiers' exit 7, the Ed25519 key rule on a chain, the crossing and a
  # legacy row after an N6 row, each in the in-app verifier and in `bin/verify_receipt.exs`.
  use Trinity.DataCase, async: false

  alias Trinity.N6.{CBOR, COSE}
  alias Trinity.Receipts
  alias Trinity.Receipts.{KeyCustody, V4, Verifier}
  alias Trinity.TestReceipts.LegacyRows

  @script Path.expand("../../../bin/verify_receipt.exs", __DIR__)
  @lib Path.expand("../../../lib", __DIR__)
  @n6_alg %{"ed25519" => -19, "p384" => -51, "mldsa87" => -50}

  setup do
    scope = "verdicts:" <> Trinity.UUID.generate()
    dir = Path.join(System.tmp_dir!(), "trinity-verdicts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Receipts.stop_writer(scope)
      File.rm_rf!(dir)
    end)

    {:ok, scope: scope, dir: dir}
  end

  defp export(scope, kinds) do
    for k <- kinds, do: {:ok, _} = Receipts.append(scope, %{kind: k, subject: %{"k" => k}})
    :ok = Receipts.stop_writer(scope)
    Process.sleep(50)
    {:ok, export} = Receipts.export(scope)
    export
  end

  defp run_script(dir, export) do
    script = Path.join(dir, "verify_receipt.exs")
    File.cp!(@script, script)
    file = Path.join(dir, "export.json")
    File.write!(file, JSON.encode!(export))

    {out, code} =
      System.cmd("elixir", [script, file, "--n6", @lib], cd: dir, stderr_to_stdout: true)

    {String.trim(out), code}
  end

  # The row at `seq` rebuilt with `edit` applied to its body and signed again by the key in custody,
  # so the signature verifies over bytes the profile refuses.
  defp resign(export, seq, edit) do
    update_in(export["receipts"], fn rows ->
      Enum.map(rows, fn
        %{"seq" => ^seq, "kind" => kind} = r ->
          {:ok, value} = CBOR.decode(Base.decode64!(r["body_b64"]))
          body = CBOR.encode!(edit.(value))
          [reg] = Enum.filter(export["registry"], &(&1["key_id"] == r["key_id"]))
          alg = Map.fetch!(@n6_alg, reg["algorithm"])
          protected = V4.protected(kind, alg, Base.decode64!(reg["public_key_b64"]))
          {:ok, sig} = KeyCustody.sign(COSE.to_be_signed(protected, body))
          {:ok, carrier} = V4.carrier(protected, body, alg, sig)

          %{
            r
            | "body_b64" => Base.encode64(body),
              "carrier_b64" => Base.encode64(carrier),
              "receipt_hash" => V4.hex(V4.statement_id(kind, body))
          }

        r ->
          r
      end)
    end)
  end

  describe "AC2: the verifiers answer exit 7" do
    test "a signed row whose verified body lacks key 1: one finding, verdict_code last, in both",
         %{scope: scope, dir: dir} do
      export = export(scope, ["query", "decision"]) |> resign(2, &Map.delete(&1, 1))

      assert Verifier.verify(export, require_coverage: false) ==
               {:error, 7,
                {:accuse, 2, :accuse_single_signed_nonconforming,
                 [nonconforming: :issuer_missing]}}

      {out, code} = run_script(dir, export)
      assert code == 7

      assert out |> String.split("\n") |> Enum.take(-2) == [
               "finding: nonconforming issuer_missing",
               "verdict_code: accuse_single_signed_nonconforming"
             ]
    end
  end

  describe "AC3: the Ed25519 key rule on a chain" do
    test "rows signed under the identity key verify under OpenSSL's equation and are key_invalid",
         %{scope: scope, dir: dir} do
      identity = <<1>> <> :binary.copy(<<0>>, 31)
      sig = identity <> :binary.copy(<<0>>, 32)
      export = export(scope, ["decision"])

      export =
        export
        |> update_in(["registry"], fn rows ->
          Enum.map(
            rows,
            &%{&1 | "algorithm" => "ed25519", "public_key_b64" => Base.encode64(identity)}
          )
        end)
        |> update_in(["receipts"], fn rows ->
          Enum.map(rows, fn r ->
            body = Base.decode64!(r["body_b64"])
            protected = V4.protected(r["kind"], -19, identity)
            {:ok, carrier} = V4.carrier(protected, body, -19, sig)
            %{r | "scheme" => "receipt_v4_ed25519", "carrier_b64" => Base.encode64(carrier)}
          end)
        end)

      assert Verifier.verify(export, require_coverage: false) ==
               {:error, 1, {:n6, 1, :key_invalid}}

      assert {out, 1} = run_script(dir, export)
      assert out =~ "{:n6, 1, :key_invalid}"
    end
  end

  describe "AC5: the crossing" do
    test "a chain crossing from v3 to v4 has one crossing finding, in both; one that never crosses has none",
         %{scope: scope, dir: dir} do
      LegacyRows.plant(scope, ["decision", "query", "decision"])
      {:ok, _} = Receipts.ensure_writer(scope)
      crossed = export(scope, ["query", "decision"])

      assert {:ok, %{findings: [crossing: 4]}} = Verifier.verify(crossed)
      assert {out, 0} = run_script(dir, crossed)
      assert out =~ "finding: {:crossing, 4}"

      plain = export("verdicts:" <> Trinity.UUID.generate(), ["decision", "query"])
      assert {:ok, %{findings: []}} = Verifier.verify(plain, require_coverage: false)
    end
  end

  describe "AC6: no legacy row after an N6 row" do
    test "a v3 row after a v4 row is refused, though its link and signature are good",
         %{scope: scope, dir: dir} do
      export = export(scope, ["decision"])
      [last] = export["receipts"]

      # Back into the database, so the export carries the planted row exactly as a writer would.
      LegacyRows.plant(scope, ["decision"], 2, last["receipt_hash"])
      {:ok, export} = Receipts.export(scope)

      assert Enum.map(export["receipts"], & &1["scheme"]) |> Enum.map(&String.slice(&1, 0, 10)) ==
               ["receipt_v4", "receipt_v3"]

      assert Verifier.verify(export, require_coverage: false) ==
               {:error, 1, {:legacy_after_n6, 2}}

      assert {out, 1} = run_script(dir, export)
      assert out =~ "{:legacy_after_n6, 2}"
    end
  end
end
