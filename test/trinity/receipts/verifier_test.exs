# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.VerifierTest do
  @moduledoc """
  Slice 024, AC3 and AC8: a chain of 1,000 mixed receipts verifies; one byte in any
  `signed_payload` gives 1; an unknown key id 5; a compromised key 6; a body claiming
  another algorithm verifies against the registry's, not the body's; a foreign family is
  refused at the scheme string before any signature is checked.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.{Envelope, Signer, Verifier}

  setup do
    scope = "verify:" <> Trinity.UUID.generate()
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, scope: scope}
  end

  defp build(scope, n) do
    old = Application.get_env(:trinity, :receipts, [])

    Application.put_env(
      :trinity,
      :receipts,
      Keyword.merge(old, checkpoint_every: 50, checkpoint_after_ms: 60_000)
    )

    try do
      for i <- 1..n do
        attrs =
          case rem(i, 4) do
            0 ->
              %{
                kind: "decision",
                subject: %{"i" => i},
                decision: %{"outcome" => "allow"},
                fingerprint: "f#{i}"
              }

            1 ->
              %{kind: "query", subject: %{"i" => i}}

            2 ->
              %{
                kind: "effect",
                subject: %{"i" => i},
                decision: %{"outcome" => "allow"},
                fingerprint: "f#{i}"
              }

            3 ->
              %{kind: "query", subject: %{"i" => i}}
          end

        {:ok, _} = Receipts.append(scope, attrs)
      end

      :ok = Receipts.stop_writer(scope)
      {:ok, export} = Receipts.export(scope)
      export
    after
      Application.put_env(:trinity, :receipts, old)
    end
  end

  defp flip_byte(payload, at) do
    <<a::binary-size(at), b, rest::binary>> = payload
    <<a::binary, Bitwise.bxor(b, 1), rest::binary>>
  end

  test "AC3: 1,000 mixed receipts verify with their checkpoints; one byte in any signed_payload is 1",
       %{scope: scope} do
    export = build(scope, 1_000)
    assert length(export["receipts"]) == 1_000
    assert length(export["checkpoints"]) >= 10
    assert {:ok, %{receipts: 1_000}} = Verifier.verify(export)

    # A byte inside the JSON text of a random row, not on a structural character: still 1,
    # because the hash no longer matches, before any signature is looked at.
    for seq <- [1, 7, 500, 1_000] do
      tampered =
        update_in(export["receipts"], fn rows ->
          Enum.map(rows, fn r ->
            if r["seq"] == seq, do: Map.update!(r, "signed_payload", &flip_byte(&1, 2)), else: r
          end)
        end)

      assert {:error, 1, reason} = Verifier.verify(tampered)

      assert elem(reason, 0) in [:hash_mismatch, :body_column_mismatch, :body_not_json],
             inspect(reason)

      assert Verifier.exit_code({:error, 1, reason}) == 1
    end
  end

  test "AC3: an unknown key id is 5 (trust not established); a compromised key is 6", %{
    scope: scope
  } do
    export = build(scope, 8)
    assert {:ok, _} = Verifier.verify(export)

    unknown = Map.put(export, "registry", [])
    assert {:error, 5, {:unknown_key_id, 1, _}} = Verifier.verify(unknown)

    compromised =
      update_in(export["registry"], fn rows ->
        rows ++
          [
            Map.merge(List.last(rows), %{
              "status" => "compromised",
              "valid_from" => "2099-01-01T00:00:00Z"
            })
          ]
      end)

    assert {:error, 6, {:key_compromised, 1, _}} = Verifier.verify(compromised)
  end

  test "AC3: a chain with a gap, a wrong prev_hash, or a forged signature is 1", %{scope: scope} do
    export = build(scope, 8)
    rows = export["receipts"]

    gap = Map.put(export, "receipts", Enum.reject(rows, &(&1["seq"] == 4)))
    assert {:error, 1, {:seq_gap, 3, 5}} = Verifier.verify(gap)

    forged =
      Map.put(
        export,
        "receipts",
        Enum.map(rows, fn r ->
          if r["kind"] == "decision",
            do: Map.put(r, "signature_b64", Base.encode64(:crypto.strong_rand_bytes(64))),
            else: r
        end)
      )

    assert {:error, 1, {:signature_invalid, _}} = Verifier.verify(forged)
  end

  test "AC8: the algorithm comes from the registry, not the body; a foreign family is refused at the scheme string",
       %{scope: scope} do
    export = build(scope, 4)
    [row | _] = export["registry"]
    # The chain's family is the selection's (Ed25519 here, P-384 on the fips leg); the foreign
    # family is the other one. P-384 signs everywhere; Ed25519 does not in FIPS mode, so the
    # half that needs a real foreign signature runs only where its signer is available.
    %{algorithm: here} = Trinity.Receipts.KeyCustody.selected()
    here_s = Atom.to_string(here)
    assert row["algorithm"] == here_s
    foreign = if here == :ed25519, do: :p384, else: :ed25519
    foreign_impl = Signer.impl(foreign)
    foreign_scheme = foreign_impl.scheme()
    here_scheme = Signer.impl(here).scheme()

    # Mutant 1 (the registry lookup dropped): a receipt whose scheme names the foreign family
    # while its key's registry row says the chain's must be refused for the family mismatch,
    # before any signature is checked; a verifier that read the algorithm from the receipt
    # would try the foreign family and report a signature failure instead. The reason names
    # the refusal, so the two are distinguishable.
    claimed =
      update_in(export["receipts"], fn rows ->
        Enum.map(rows, fn r ->
          if r["seq"] == 1, do: Map.put(r, "scheme", foreign_scheme), else: r
        end)
      end)

    assert {:error, 1, {:scheme_family_mismatch, 1, ^foreign_scheme, ^here_s}} =
             Verifier.verify(claimed)

    # The same with the body and the hash rewritten to agree with the column (an attacker who
    # controls the row controls all three): the registry row's family still refuses the scheme.
    rebuilt =
      update_in(export["receipts"], fn rows ->
        Enum.map(rows, fn r ->
          if r["seq"] == 1 do
            body = r["signed_payload"] |> JSON.decode!() |> Map.put("scheme", foreign_scheme)
            payload = Envelope.canonical(body)
            bytes = Envelope.pae(Envelope.receipt_type(foreign_scheme), payload)

            %{
              r
              | "scheme" => foreign_scheme,
                "signed_payload" => payload,
                "receipt_hash" => Envelope.hash(bytes)
            }
          else
            r
          end
        end)
      end)

    assert {:error, 1, {:scheme_family_mismatch, 1, ^foreign_scheme, ^here_s}} =
             Verifier.verify(rebuilt)

    # Mutant 2 (the scheme check dropped): a receipt of the foreign family with its own key in
    # the registry, presented to a verifier told to accept only the chain's family, is refused
    # at the scheme string. Where the foreign signer is available the same row, with all three
    # schemes allowed, is a valid row on its own; where it is not (Ed25519 in FIPS mode) the
    # row carries a signature that cannot be made here and only the refusal is asserted.
    {pub, sig_fun} =
      if foreign_impl.available?() do
        {pub, priv} = foreign_impl.generate_key()
        {pub, fn bytes -> foreign_impl.sign(bytes, priv) end}
      else
        {:crypto.strong_rand_bytes(32), fn _ -> :crypto.strong_rand_bytes(64) end}
      end

    jwk = foreign_impl.jwk(pub)

    foreign_id =
      if jwk,
        do: Signer.thumbprint(jwk),
        else: Base.url_encode64(:crypto.hash(:sha256, pub), padding: false)

    foreign_row = %{
      "key_id" => foreign_id,
      "algorithm" => Atom.to_string(foreign),
      "scheme" => foreign_scheme,
      "jwk" => jwk,
      "public_key_b64" => Base.encode64(pub),
      "status" => "active",
      "valid_from" => "2026-09-20T00:00:00Z",
      "kid_scheme" => "rfc7638"
    }

    body = %{
      "scheme" => foreign_scheme,
      "seq" => 1,
      "chain_scope" => "other",
      "prev_hash" => nil,
      "kind" => "decision",
      "subject" => %{},
      "decision" => %{"outcome" => "allow"},
      "fingerprint" => nil,
      "at" => "2026-09-20T00:00:00Z",
      "key_id" => foreign_id
    }

    payload = Envelope.canonical(body)
    bytes = Envelope.pae(Envelope.receipt_type(foreign_scheme), payload)

    foreign_export = %{
      "receipts" => [
        %{
          "chain_scope" => "other",
          "seq" => 1,
          "prev_hash" => nil,
          "receipt_hash" => Envelope.hash(bytes),
          "scheme" => foreign_scheme,
          "kind" => "decision",
          "signed_payload" => payload,
          "signature_b64" => Base.encode64(sig_fun.(bytes)),
          "key_id" => foreign_id,
          "meta" => %{}
        }
      ],
      "checkpoints" => [],
      "registry" => [foreign_row]
    }

    if foreign_impl.available?(),
      do: assert({:ok, %{receipts: 1}} = Verifier.verify(foreign_export))

    assert {:error, 1, {:scheme_not_allowed, 1, ^foreign_scheme}} =
             Verifier.verify(foreign_export, schemes: [here_scheme])
  end

  test "coverage: a query receipt no checkpoint covers is 1 unless the caller waives coverage", %{
    scope: scope
  } do
    export = build(scope, 8)
    assert {:ok, _} = Verifier.verify(export)
    uncovered = Map.put(export, "checkpoints", [])
    assert {:error, 1, {:query_receipts_uncovered, [1, 3, 5, 7]}} = Verifier.verify(uncovered)
    assert {:ok, _} = Verifier.verify(uncovered, require_coverage: false)
  end
end
