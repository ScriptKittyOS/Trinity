# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.StandaloneVerifierTest do
  @moduledoc """
  Slice 024, AC7: `bin/verify_receipt.exs` runs from an empty directory, with `elixir` alone,
  against an exported file, and answers with the exit vocabulary. And the drift guard: on
  the same inputs it agrees with `Trinity.Receipts.Verifier`, outcome for outcome.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.Verifier

  @script Path.expand("../../../bin/verify_receipt.exs", __DIR__)

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
  defp run_script(dir, export, args \\ []) do
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
            do: Map.put(&1, "signed_payload", &1["signed_payload"] <> " "),
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
             run_script(dir, export, ["--schemes", other_scheme()])

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
end
