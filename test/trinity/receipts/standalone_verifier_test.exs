# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.StandaloneVerifierTest do
  @moduledoc """
  Slice 024, AC7: `bin/verify_receipt.exs` runs from an empty directory, with `elixir` alone,
  against an exported file, and answers with the exit vocabulary. And the drift guard: on
  the same inputs it agrees with `Trinity.Receipts.Verifier`, outcome for outcome.

  Slice 140, AC8: the chains the writer builds are v4, which the script verifies by loading the N6
  sources and `Trinity.Receipts.V4` from the directory `--n6` names (here, this checkout's `lib/`);
  a chain with no v4 row needs no `--n6` at all.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.Verifier

  @script Path.expand("../../../bin/verify_receipt.exs", __DIR__)
  @lib Path.expand("../../../lib", __DIR__)
  @n6 ["--n6", @lib]

  setup do
    scope = "standalone:" <> Trinity.UUID.generate()
    dir = Path.join(System.tmp_dir!(), "trinity-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Receipts.stop_writer(scope)
      File.rm_rf!(dir)
    end)

    {:ok, scope: scope, dir: dir}
  end

  defp export(scope, n) do
    for i <- 1..n do
      attrs =
        if rem(i, 2) == 0,
          do: %{
            kind: "effect",
            subject: %{"i" => i},
            decision: %{"outcome" => "allow"},
            fingerprint: "f#{i}"
          },
          else: %{kind: "query", subject: %{"i" => i}}

      {:ok, _} = Receipts.append(scope, attrs)
    end

    :ok = Receipts.stop_writer(scope)
    {:ok, export} = Receipts.export(scope)
    export
  end

  # The script copied into the empty directory, run there with only elixir on the path.
  defp run_script(dir, export, args \\ @n6) do
    script = Path.join(dir, "verify_receipt.exs")
    File.cp!(@script, script)
    file = Path.join(dir, "export.json")
    File.write!(file, JSON.encode!(export))
    assert File.ls!(dir) |> Enum.sort() == ["export.json", "verify_receipt.exs"]
    {out, code} = System.cmd("elixir", [script, file | args], cd: dir, stderr_to_stdout: true)
    {String.trim(out), code}
  end

  test "AC7: a stranger's run from an empty directory: verified is 0; the outcomes carry their codes",
       %{scope: scope, dir: dir} do
    export = export(scope, 12)
    assert {"verified: 12 receipts, 1 checkpoints", 0} = run_script(dir, export)

    tampered =
      update_in(export["receipts"], fn rows ->
        Enum.map(
          rows,
          &if(&1["seq"] == 6,
            do: Map.put(&1, "body_b64", Base.encode64(Base.decode64!(&1["body_b64"]) <> <<0>>)),
            else: &1
          )
        )
      end)

    assert {"invalid: " <> _, 1} = run_script(dir, tampered)

    assert {"trust not established: " <> _, 5} = run_script(dir, Map.put(export, "registry", []))

    compromised =
      update_in(export["registry"], fn rows ->
        rows ++ [Map.put(List.last(rows), "status", "compromised")]
      end)

    assert {"compromised key: " <> _, 6} = run_script(dir, compromised)

    assert {"invalid: {:scheme_not_allowed, " <> _, 1} =
             run_script(dir, export, ["--schemes", other_scheme() | @n6])

    # Copied out of the checkout with no `--n6`, a v4 chain is a usage error, never a verdict.
    {out, 2} = run_script(dir, export, [])
    assert out =~ "v4 rows need Trinity's N6 sources"

    {out, 2} =
      System.cmd("elixir", [Path.join(dir, "verify_receipt.exs")],
        cd: dir,
        stderr_to_stdout: true
      )

    assert out =~ "usage"
  end

  # A scheme the chain is not: P-384's where the selection is Ed25519, Ed25519's on the fips leg.
  defp other_scheme do
    case Trinity.Receipts.KeyCustody.selected() do
      %{algorithm: :ed25519} -> "receipt_v2_p384"
      _ -> "receipt_v2_ed25519"
    end
  end

  test "the script and the in-app verifier agree on every outcome", %{scope: scope, dir: dir} do
    export = export(scope, 12)

    variants = [
      export,
      update_in(export["receipts"], fn rows ->
        Enum.map(
          rows,
          &if(&1["seq"] == 3,
            do: Map.put(&1, "receipt_hash", String.duplicate("a", 64)),
            else: &1
          )
        )
      end),
      Map.put(export, "registry", []),
      update_in(export["registry"], fn rows ->
        rows ++ [Map.put(List.last(rows), "status", "compromised")]
      end),
      Map.put(export, "checkpoints", []),
      Map.put(export, "receipts", Enum.reject(export["receipts"], &(&1["seq"] == 5)))
    ]

    for v <- variants do
      {_out, code} = run_script(dir, v)
      assert code == Verifier.exit_code(Verifier.verify(v))
    end
  end

  test "AC8: a missing or altered attachment is a finding in both, and the verdict stands", %{
    scope: scope,
    dir: dir
  } do
    export = export(scope, 4)

    missing =
      update_in(export["receipts"], fn rows ->
        Enum.map(rows, &if(&1["seq"] == 2, do: Map.delete(&1, "subject_b64"), else: &1))
      end)

    altered =
      update_in(export["receipts"], fn rows ->
        Enum.map(
          rows,
          &if(&1["seq"] == 4,
            do: Map.put(&1, "decision_b64", Base.encode64(~s({"outcome":"deny"}))),
            else: &1
          )
        )
      end)

    assert {:ok, %{findings: [{:foreign_bytes_missing, 2, :subject}]}} = Verifier.verify(missing)
    assert {out, 0} = run_script(dir, missing)
    assert out =~ "finding: {:foreign_bytes_missing, 2, :subject}"

    assert {:ok, %{findings: [{:foreign_digest_mismatch, 4, :decision}]}} =
             Verifier.verify(altered)

    assert {out, 0} = run_script(dir, altered)
    assert out =~ "finding: {:foreign_digest_mismatch, 4, :decision}"
  end

  test "AC8: on a chain that crosses from v3 to v4, and on each tamper of it, both agree", %{
    scope: scope,
    dir: dir
  } do
    Trinity.TestReceipts.LegacyRows.plant(scope, ["decision", "query", "decision"])
    {:ok, _} = Receipts.ensure_writer(scope)
    for k <- ["query", "decision"], do: {:ok, _} = Receipts.append(scope, %{kind: k})
    :ok = Receipts.stop_writer(scope)
    Process.sleep(50)
    {:ok, export} = Receipts.export(scope)

    at = fn path, value -> put_in(export, path, value) end

    variants = [
      export,
      at.(["receipts", Access.at(3), "prev_hash"], String.duplicate("0", 96)),
      at.(["receipts", Access.at(2), "signed_payload"], "{}"),
      at.(["checkpoints", Access.at(0), "tail_hash"], String.duplicate("0", 96)),
      Map.put(export, "receipts", List.delete_at(export["receipts"], 3))
    ]

    codes =
      for v <- variants do
        {_out, code} = run_script(dir, v)
        assert code == Verifier.exit_code(Verifier.verify(v))
        code
      end

    assert hd(codes) == 0
    assert Enum.all?(tl(codes), &(&1 == 1))
  end

  test "AC8: a v3 chain verifies without --n6, as before slice 140, and both agree", %{dir: dir} do
    # Slice 139's fixture, an Ed25519 chain written under v3.
    export = "test/fixtures/receipts/ed25519_signed.json" |> File.read!() |> JSON.decode!()
    assert Enum.all?(export["receipts"], &String.starts_with?(&1["scheme"], "receipt_v3_"))

    {_out, code} = run_script(dir, export, [])
    assert code == Verifier.exit_code(Verifier.verify(export))
    assert code in [0, 5]
  end
end
