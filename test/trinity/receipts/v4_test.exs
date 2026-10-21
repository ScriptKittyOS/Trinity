# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.V4Test do
  @moduledoc """
  Slice 140: receipts v4. AC3, the six kinds' bodies; AC4, `subject` and `decision` by ForeignRef;
  AC5, linking, across the bump from v3 included; AC6, the writer and the `nss` profile; AC7, every
  verifier on a chain that mixes v3 and v4 rows and checkpoints.
  """
  use Trinity.DataCase, async: false

  alias Trinity.N6.{Carrier, CBOR, COSE, Digest}
  alias Trinity.Receipts
  alias Trinity.Receipts.{ChainWriter, Envelope, KeyCustody, Merge, Receipt, Signer, V4, Verifier}
  alias Trinity.TestReceipts.LegacyRows

  setup do
    scope = "v4:" <> Trinity.UUID.generate()
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, scope: scope}
  end

  defp fields(overrides \\ %{}) do
    Map.merge(
      %{
        issuer: "trinity:test",
        seq: 2,
        chain_scope: "s",
        prev: :binary.copy(<<7>>, 48),
        at: 1_792_500_000_000_000,
        clock: {1_792_500_000_000, 3, "node-a"},
        subject: ~s({"a":1}),
        decision: ~s({"outcome":"allow"}),
        fingerprint: "ab01"
      },
      overrides
    )
  end

  defp export!(scope) do
    :ok = Receipts.stop_writer(scope)
    await_stopped(scope)
    {:ok, export} = Receipts.export(scope)
    export
  end

  defp await_stopped(scope) do
    if ChainWriter.whereis(scope), do: Process.sleep(10) && await_stopped(scope), else: :ok
  end

  describe "AC3: the six kinds" do
    test "each row kind builds and reads back to the same fields, under its own key 0 and typ" do
      for {kind, n} <- V4.kinds(), kind != "checkpoint" do
        assert {:ok, body} = V4.row_body(kind, fields())
        assert {:ok, v} = V4.read(kind, body)
        assert v[0] == Bitwise.bsl(0x83, 24) + Bitwise.bsl(n, 8) + 1
        assert v[1] == {:text, "trinity:test"} and v[16] == 2 and v[17] == {:text, "s"}
        assert v[7] == [-43, {:bytes, :binary.copy(<<7>>, 48)}]
        assert v[18] == 1_792_500_000_000_000
        assert v[19] == %{1 => 1_792_500_000_000, 2 => 3, 3 => {:text, "node-a"}}
        assert v[20] == Digest.foreign_ref(~s({"a":1}), "application/json")
        assert v[21] == Digest.foreign_ref(~s({"outcome":"allow"}), "application/json")
        assert v[22] == {:text, "ab01"}
        assert V4.typ(kind) == "application/vnd.example.b83.receipt-#{kind}.v0+cose"
      end

      # A row with no predecessor, no decision and no fingerprint leaves the keys out.
      assert {:ok, body} =
               V4.row_body("query", fields(%{prev: nil, decision: nil, fingerprint: nil}))

      assert {:ok, v} = V4.read("query", body)
      assert v |> Map.keys() |> Enum.sort() == [0, 1, 16, 17, 18, 19, 20]
    end

    test "a checkpoint builds and reads back" do
      f = %{
        issuer: "trinity:test",
        first_seq: 1,
        last_seq: 9,
        chain_scope: "s",
        tail: :binary.copy(<<9>>, 48),
        boot: "abc",
        reason: "count",
        at: 5
      }

      assert {:ok, body} = V4.checkpoint_body(f)
      assert {:ok, v} = V4.read("checkpoint", body)
      assert v[0] == V4.schema_number("checkpoint") and v[16] == 1 and v[20] == 9
      assert v[21] == [-43, {:bytes, :binary.copy(<<9>>, 48)}] and v[23] == {:text, "count"}
    end

    test "a body under another kind's schema, an undeclared key, a missing key or a wrong type is refused" do
      {:ok, body} = V4.row_body("decision", fields())
      {:ok, v} = CBOR.decode(body)

      assert V4.read("effect", body) == :error

      for {mutant, code} <- [
            {Map.put(v, 30, 1), :unknown_key},
            {Map.delete(v, 16), :field_missing},
            {Map.put(v, 16, {:text, "two"}), :field_type_mismatch},
            {Map.put(v, 0, V4.schema_number("effect")), :unknown_schema}
          ] do
        assert {:error, ^code, _} =
                 Trinity.N6.Body.decode(
                   CBOR.encode!(mutant),
                   "trinity.receipt.decision",
                   V4.schemas()
                 )
      end
    end

    test "the encoder refuses a body the decoder would refuse" do
      assert {:error, :value_out_of_range} = V4.row_body("decision", fields(%{seq: -1}))
    end

    test "the typ table has one single-signer entry per signed kind and none for query" do
      table = V4.typ_table()
      assert map_size(table) == 5
      refute Map.has_key?(table, V4.typ("query"))

      for {typ, entry} <- table do
        assert %{carrier: :single, signers: :single, scitt: false, schema: schema} = entry
        assert typ == V4.typ(Enum.find(Map.keys(V4.kinds()), &(V4.schema_number(&1) == schema)))
      end
    end
  end

  describe "AC4: subject and decision by ForeignRef" do
    test "the stored bytes match, and re-serialising them with another key order is only a finding",
         %{scope: scope} do
      {:ok, _} =
        Receipts.append(scope, %{
          kind: "decision",
          subject: %{"b" => 2, "a" => 1},
          decision: %{"outcome" => "allow", "basis" => "rule"}
        })

      export = export!(scope)
      [r] = export["receipts"]
      assert Base.decode64!(r["subject_b64"]) == ~s({"a":1,"b":2})
      assert {:ok, %{findings: []}} = Verifier.verify(export)

      # The same map, other key order: the same JSON value, other bytes.
      reordered = Base.encode64(~s({"b":2,"a":1}))
      tampered = put_in(export, ["receipts", Access.at(0), "subject_b64"], reordered)

      assert {:ok, %{findings: [{:foreign_digest_mismatch, 1, :subject}]}} =
               Verifier.verify(tampered)
    end
  end

  describe "AC5: linking" do
    test "a v4 row's link is its statement_id, the same whether or not it is signed", %{
      scope: scope
    } do
      for k <- ["query", "decision", "query"], do: {:ok, _} = Receipts.append(scope, %{kind: k})

      [a, b, c] = Receipts.list(scope)
      assert b.prev_hash == a.receipt_hash and c.prev_hash == b.receipt_hash
      assert a.receipt_hash == V4.hex(V4.statement_id("query", a.body))

      # The query row's body, signed: the carrier's payload is the body, so the id is unchanged.
      %{n6_alg: alg, public: pub} = KeyCustody.selected()
      protected = V4.protected("query", alg, pub)
      {:ok, sig} = KeyCustody.sign(COSE.to_be_signed(protected, a.body))
      {:ok, carrier} = V4.carrier(protected, a.body, alg, sig)
      {:ok, %{payload: payload}} = Carrier.decode(carrier)
      assert V4.hex(V4.statement_id("query", payload)) == a.receipt_hash
    end

    test "a chain that began in v3 continues in v4, linked by SHA-384 over the v3 row's PAE bytes",
         %{scope: scope} do
      [_, v3] = LegacyRows.plant(scope, ["decision", "decision"])
      {:ok, v4} = Receipts.append(scope, %{kind: "decision", decision: %{"outcome" => "allow"}})

      assert Signer.n6?(v4.scheme) and v4.seq == 3
      pae = Envelope.pae(Envelope.receipt_type(v3.scheme), v3.signed_payload)
      assert v4.prev_hash == V4.hex(:crypto.hash(:sha384, pae))
      assert {:ok, %{7 => [-43, {:bytes, link}]}} = V4.read("decision", v4.body)
      assert link == :crypto.hash(:sha384, pae)

      assert {:ok, %{receipts: 3}} = Verifier.verify(export!(scope))
    end

    test "every tamper with a row, a link or a checkpoint is refused at its seq", %{scope: scope} do
      for k <- ["decision", "query", "decision", "query", "decision"],
          do: {:ok, _} = Receipts.append(scope, %{kind: k})

      {:ok, _} = ChainWriter.checkpoint(scope, "manual")
      export = export!(scope)
      assert {:ok, %{receipts: 5}} = Verifier.verify(export)
      rows = export["receipts"]

      # Reordered: rows 2 and 3 exchange their positions.
      reordered =
        Enum.map(rows, fn r ->
          case r["seq"] do
            2 -> %{r | "seq" => 3}
            3 -> %{r | "seq" => 2}
            _ -> r
          end
        end)

      cases = [
        {Map.put(export, "receipts", List.delete_at(rows, 2)), {:seq_gap, 2, 4}},
        {Map.put(export, "receipts", reordered), {:prev_hash_mismatch, 2}},
        {put_in(export, ["receipts", Access.at(3), "prev_hash"], String.duplicate("0", 96)),
         {:prev_hash_mismatch, 4}},
        {put_in(export, ["checkpoints", Access.at(0), "tail_hash"], String.duplicate("0", 96)),
         {:checkpoint_tail_mismatch, 5}}
      ]

      for {variant, reason} <- cases do
        assert {:error, 1, ^reason} = Verifier.verify(variant)
      end
    end
  end

  describe "AC6: the writer and the profile" do
    test "the writer writes v4 under the selected key's algorithm" do
      %{algorithm: alg, n6_alg: n6, scheme: scheme} = KeyCustody.selected()
      assert scheme == "receipt_v4_#{alg}"
      assert n6 == %{ed25519: -19, p384: -51, mldsa87: -50}[alg]

      IO.puts("v4_test: the writer signs v4 with #{alg} (#{n6}), fips #{:crypto.info_fips()}")
    end

    test "the nss profile admits ML-DSA-87 only, refused at selection naming both" do
      old = Application.get_env(:trinity, :receipts, [])
      on_exit(fn -> Application.put_env(:trinity, :receipts, old) end)

      for alg <- [:ed25519, :p384] do
        Application.put_env(
          :trinity,
          :receipts,
          Keyword.merge(old, profile: :nss, algorithm: alg)
        )

        assert KeyCustody.select() == {:error, {:receipts_profile_algorithm, :nss, alg}}

        assert Trinity.Profile.check_receipts(:regulated, KeyCustody.select()) ==
                 {:error,
                  {:regulated_requires_receipts, {:receipts_profile_algorithm, :nss, alg}}}
      end

      Application.put_env(
        :trinity,
        :receipts,
        Keyword.merge(old, profile: :nss, algorithm: :mldsa87)
      )

      refute match?({:error, {:receipts_profile_algorithm, _, _}}, KeyCustody.select())
      assert KeyCustody.profile() == :nss
    end
  end

  describe "AC6: ML-DSA-87 (-50), where the runtime signs it" do
    # The `fips` job's mode-off step runs this file with ML-DSA-87 required; elsewhere the tag
    # excludes it.
    @tag :mldsa87_runtime
    test "with ML-DSA-87 configured on the nss profile, the writer signs v4 with -50 and it verifies at nss",
         %{scope: scope} do
      old = Application.get_env(:trinity, :receipts, [])

      dir =
        Path.join(System.tmp_dir!(), "trinity-v4-mldsa87-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        Application.put_env(:trinity, :receipts, old)
        File.rm_rf!(dir)
        {:ok, _} = KeyCustody.boot!()
      end)

      # The export reads the registry from the configured keys directory, so the key goes there.
      Application.put_env(
        :trinity,
        :receipts,
        Keyword.merge(old, algorithm: :mldsa87, profile: :nss, keys_dir: dir)
      )

      assert {:ok, %{algorithm: :mldsa87, n6_alg: -50, scheme: "receipt_v4_mldsa87"}} =
               KeyCustody.boot!()

      for k <- ["decision", "query", "effect"], do: {:ok, _} = Receipts.append(scope, %{kind: k})

      for r <- Receipts.list(scope), r.carrier do
        {:ok, parts} = Carrier.decode(r.carrier)
        assert {:ok, %{1 => -50}} = CBOR.decode(parts.protected)
        assert byte_size(parts.signature) == 4627
      end

      export = export!(scope)
      assert {:ok, %{receipts: 3}} = Verifier.verify(export, entry: :nss)
      IO.puts("v4_test: ML-DSA-87 (-50) v4 rows written and verified at nss")
    end
  end

  describe "AC7: every verifier on a chain that mixes v3 and v4" do
    test "the verifier, the merge and the writer's rehydrate all accept it", %{scope: scope} do
      LegacyRows.plant(scope, ["decision", "query", "decision"])

      # The writer starts over the v3 tail: its rehydrate checkpoint covers the v3 query row in v4.
      {:ok, _} = Receipts.ensure_writer(scope)
      for k <- ["query", "decision", "query"], do: {:ok, _} = Receipts.append(scope, %{kind: k})

      export = export!(scope)
      schemes = Enum.map(export["receipts"], &elem(Signer.parse_scheme(&1["scheme"]), 1))
      assert schemes == ["v3", "v3", "v3", "v4", "v4", "v4"]
      assert Enum.any?(export["checkpoints"], &(&1["first_seq"] == 2 and &1["body_b64"]))

      assert {:ok, %{receipts: 6, findings: []}} = Verifier.verify(export)
      assert {:ok, :identical, %{conflicts: []}} = Merge.merge(scope, export)

      # A restart rehydrates over the v4 tail and its v4 checkpoint, and the chain continues.
      {:ok, _} = Receipts.ensure_writer(scope)
      assert {:ok, %Receipt{seq: 7}} = Receipts.append(scope, %{kind: "decision"})
      assert {:ok, %{receipts: 7}} = Verifier.verify(export!(scope))
    end
  end
end
