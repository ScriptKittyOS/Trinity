# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.CarrierTest do
  @moduledoc """
  Slice 139, AC4 and AC5: the single-signer carrier, `{0: SINGLE_SCHEMA, 1: payload, 2: N6_Sign1}`,
  built, parsed and verified, and every sample in `test/fixtures/n6/cose/sign1/` giving the outcome
  its `.expect` names under its `.ctx.json`.

  The signed samples are Ed25519 and, since slice 140, ESP384. Where the runtime refuses Ed25519
  (FIPS mode), an Ed25519 sample whose outcome needs the signature checked answers `alg_unavailable`
  (5) instead, and every other sample keeps its code, because those are decided before any signature
  is looked at. ESP384 is judged on every runtime here, FIPS mode included. Since slice 140 the body
  rules (`typ_schema_mismatch`, `issuer_missing`) are read after the signature, so they are judged
  outcomes too.
  """

  use ExUnit.Case, async: true

  alias Trinity.N6.{Carrier, CBOR, COSE, Profile}
  alias Trinity.TestSupport.{Ed25519Oracle, N6Vectors}

  # The outcomes that need the signature checked.
  @judged [
    :claim,
    :signature_invalid,
    :accuse_single_signed_noncanonical,
    :accuse_single_signed_nonconforming
  ]

  test "AC5: every sample gives its expected outcome under its context" do
    samples = N6Vectors.samples()
    assert length(samples) >= 26
    ed25519? = Ed25519Oracle.verifies?()

    for {id, bytes, exit, code, findings, opts} <- samples do
      answer = Carrier.verify(bytes, opts)

      cond do
        code in @judged and alg(bytes) == -19 and not ed25519? ->
          assert answer == {:error, 5, :alg_unavailable}, id

        code == :claim ->
          assert {:ok, %{exit: 0, verdict_code: :claim}} = answer, id

        exit == 7 ->
          assert answer == {:error, 7, {code, findings}}, id
          assert [_one] = findings, id

        true ->
          assert answer == {:error, exit, code}, id
          assert Profile.exit_of(code) == exit
      end
    end
  end

  # The header's `alg`, read from the sample's own bytes.
  defp alg(bytes) do
    {:ok, %{0 => _, 2 => [{:bytes, protected} | _]}} = CBOR.decode(bytes)
    {:ok, %{1 => alg}} = CBOR.decode(protected)
    alg
  end

  test "AC4: the carrier round-trips its parts, and its key 0 is the publisher's schema" do
    bytes = File.read!(Path.join(N6Vectors.root(), "cose/sign1/ed25519_single.bin"))
    assert {:ok, parts} = Carrier.decode(bytes)
    assert Carrier.encode(parts) == bytes

    assert {:ok, %{0 => 0xFFFF0003, 1 => {:bytes, payload}}} = CBOR.decode(bytes)
    assert payload == parts.payload
    assert Profile.schemas().single == {0xFFFF0003, :draft}
  end

  test "AC4: the twin envelope's schema, and a body's schema, are not a single-signer carrier" do
    {:ok, parts} =
      Carrier.decode(File.read!(Path.join(N6Vectors.root(), "cose/sign1/ed25519_single.bin")))

    sign1 = [{:bytes, parts.protected}, %{}, nil, {:bytes, parts.signature}]

    for schema <- [Profile.schema(:envelope), Profile.schema(:statement_id), 1] do
      bytes = CBOR.encode!(%{0 => schema, 1 => {:bytes, parts.payload}, 2 => sign1})
      assert Carrier.decode(bytes) == {:error, :carrier_malformed}, "schema #{schema}"
    end
  end

  test "AC4: a pair typ is refused before the signature, whatever the signature" do
    [{_, bytes, _, :wrong_carrier_for_typ, [], opts}] =
      Enum.filter(N6Vectors.samples(), &(elem(&1, 3) == :wrong_carrier_for_typ))

    # The sample's signature is 4,627 zero bytes: refused for its typ, never judged.
    assert {:ok, %{signature: sig}} = Carrier.decode(bytes)
    assert sig == :binary.copy(<<0>>, 4627)
    assert Carrier.verify(bytes, opts) == {:error, 1, :wrong_carrier_for_typ}

    assert Carrier.verify(bytes, Keyword.put(opts, :entry, :nss)) ==
             {:error, 1, :wrong_carrier_for_typ}
  end

  test "an unknown key in a carrier is no trust, as for a bare Sign1" do
    bytes = File.read!(Path.join(N6Vectors.root(), "cose/sign1/ed25519_single.bin"))

    opts = [keys: fn _ -> :error end, typ: N6Vectors.typ_table(), entry: :commercial]
    assert Carrier.verify(bytes, opts) == {:error, 5, :policy_stale_or_unknown_key}
    assert {:ok, parts} = Carrier.decode(bytes)
    assert COSE.verify(parts, opts) == {:error, 5, :policy_stale_or_unknown_key}
  end
end
