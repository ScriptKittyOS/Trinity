# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.ForeignAlgorithmTest do
  @moduledoc """
  Slice 139, AC6 and AC7: a chain signed under an algorithm this runtime refuses gets an answer,
  not an exception. The chains are `test/fixtures/receipts/`, signed under published test keys
  (`scripts/receipt_foreign_chains.exs`): Ed25519, which FIPS mode refuses, and ML-DSA-87, which
  FIPS mode on Red Hat's provider and every OpenSSL before 3.5 refuse.

  Before slice 139, `Verifier.verify/2` and a writer rehydrating over such a checkpoint raised
  (slice 137's follow-up, seen on the `fips` job). Where the runtime has the algorithm, the same
  chains verify, so each leg of CI takes one branch of each test and PROOF says which.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.{ChainWriter, Checkpoint, KeyCustody, KeyRegistry, Receipt, Verifier}
  alias Trinity.Repo.Receipts, as: RRepo
  alias Trinity.TestSupport.{Ed25519Oracle, MLDSA87Oracle}

  @fixtures "test/fixtures/receipts"
  @script Path.expand("../../../bin/verify_receipt.exs", __DIR__)

  defp runtime_has?("ed25519"), do: Ed25519Oracle.verifies?()
  defp runtime_has?("mldsa87"), do: MLDSA87Oracle.signs?()

  defp fixture(name), do: Path.join(@fixtures, name) |> File.read!() |> JSON.decode!()

  setup_all do
    branches =
      for alg <- ~w(ed25519 mldsa87),
          do: "#{alg} #{if runtime_has?(alg), do: "verifies", else: "is refused"}"

    IO.puts(
      "foreign_algorithm_test: on this runtime (fips #{:crypto.info_fips()}) " <>
        Enum.join(branches, ", ")
    )

    :ok
  end

  describe "AC6: the verifier answers" do
    for alg <- ~w(ed25519 mldsa87),
        {chain, at} <- [{"signed", 1}, {"checkpoint", {:checkpoint, 1}}] do
      @alg alg
      @chain chain
      @at at
      test "#{alg}, #{chain}: verified where the runtime has it, else no trust naming the row" do
        export = fixture("#{@alg}_#{@chain}.json")
        answer = Verifier.verify(export)

        if runtime_has?(@alg) do
          assert {:ok, _} = answer
        else
          assert answer == {:error, 5, {:alg_unavailable, @at, @alg}}
        end
      end
    end

    # `:crypto` raises the same shapes for a key it cannot use as for an algorithm it refuses, so a
    # catch on the shape alone would call a malformed registry key a refused algorithm.
    test "a registered key the runtime cannot use is named as the key, where it has the algorithm" do
      export = short_key(fixture("ed25519_signed.json"))
      [%{"key_id" => key_id}] = export["registry"]

      if runtime_has?("ed25519") do
        assert Verifier.verify(export) == {:error, 5, {:key_undecodable, key_id}}
      else
        assert Verifier.verify(export) == {:error, 5, {:alg_unavailable, 1, "ed25519"}}
      end
    end

    @tag :tmp_dir
    test "bin/verify_receipt.exs gives the same exit on every chain", %{tmp_dir: dir} do
      script = Path.join(dir, "verify_receipt.exs")
      File.cp!(@script, script)

      chains =
        for name <-
              File.ls!(@fixtures) |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort(),
            do: {name, fixture(name)}

      for {name, export} <- [{"short_key", short_key(fixture("ed25519_signed.json"))} | chains] do
        file = Path.join(dir, name <> ".export")
        File.write!(file, JSON.encode!(export))
        {out, code} = System.cmd("elixir", [script, file], cd: dir, stderr_to_stdout: true)

        assert code == Verifier.exit_code(Verifier.verify(export)), "#{name}:\n#{out}"
      end
    end
  end

  # The chain with its registered Ed25519 key cut to 31 bytes.
  defp short_key(export) do
    update_in(export, ["registry", Access.at(0), "public_key_b64"], fn b64 ->
      b64 |> Base.decode64!() |> binary_part(0, 31) |> Base.encode64()
    end)
  end

  describe "AC7: a writer over a checkpoint it cannot verify" do
    setup do
      %{keys_dir: dir} = KeyCustody.selected()
      path = KeyRegistry.path(dir)
      before = File.read!(path)
      on_exit(fn -> File.write!(path, before) end)
      %{keys_dir: dir}
    end

    for alg <- ~w(ed25519 mldsa87) do
      @alg alg
      test "#{alg}: starts where the runtime has it, else stops with a named reason", %{
        keys_dir: dir
      } do
        export = fixture("#{@alg}_checkpoint.json")
        [row] = export["registry"]
        {:ok, _} = KeyRegistry.append(dir, row)

        scope = "foreign:" <> @alg <> ":" <> Trinity.UUID.generate()
        [r] = export["receipts"]
        [cp] = export["checkpoints"]

        RRepo.insert!(%Receipt{
          chain_scope: scope,
          seq: r["seq"],
          prev_hash: r["prev_hash"],
          receipt_hash: r["receipt_hash"],
          scheme: r["scheme"],
          kind: r["kind"],
          signed_payload: r["signed_payload"],
          key_id: r["key_id"],
          inserted_at: DateTime.utc_now()
        })

        RRepo.insert!(%Checkpoint{
          chain_scope: scope,
          first_seq: cp["first_seq"],
          last_seq: cp["last_seq"],
          tail_hash: cp["tail_hash"],
          scheme: cp["scheme"],
          signed_payload: cp["signed_payload"],
          signature: Base.decode64!(cp["signature_b64"]),
          key_id: cp["key_id"],
          reason: cp["reason"],
          inserted_at: DateTime.utc_now()
        })

        Process.flag(:trap_exit, true)
        on_exit(fn -> Receipts.stop_writer(scope) end)

        if runtime_has?(@alg) do
          assert {:ok, pid} = ChainWriter.start_link(scope)
          GenServer.stop(pid)
        else
          assert ChainWriter.start_link(scope) ==
                   {:error, {:chain_inconsistent, scope, {:checkpoint_alg_unavailable, 1, @alg}}}
        end
      end
    end
  end
end
