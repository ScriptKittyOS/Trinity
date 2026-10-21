# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.VerdictsTest do
  # Slice 144: exit 7 for a defect in bytes a verified signature covers, and the Ed25519 rule of
  # N6 draft v0.1-r7 section 5.3, at the carrier.
  use ExUnit.Case, async: true

  alias Trinity.N6.{Carrier, CBOR, COSE, Ed25519}
  alias Trinity.TestSupport.{Ed25519Oracle, Ed25519Points, N6Vectors}

  @typ "application/vnd.example.test-ed25519.v1+cose"
  @key N6Vectors.rfc8032_key()

  defp carrier(body, signature_fun, pub \\ @key.public) do
    protected = COSE.protected_header(COSE.thumbprint(-19, pub), @typ, nil, -19)
    sig = signature_fun.(COSE.to_be_signed(protected, body))
    Carrier.encode(%{protected: protected, payload: body, signature: sig})
  end

  defp signed(tbs), do: :crypto.sign(:eddsa, :none, tbs, [@key.private, :ed25519])
  defp verify(bytes, pub \\ @key.public), do: Carrier.verify(bytes, opts(pub))

  defp opts(pub),
    do: [
      keys: fn _kid -> {:ok, %{alg: -19, public: pub}} end,
      typ: N6Vectors.typ_table(),
      entry: :commercial
    ]

  # A signature the key's holder can make with R chosen: S = r + k * a.
  defp chosen_r(r_point, r_scalar, tbs) do
    r = Ed25519Points.encode(r_point)
    k = Ed25519Points.challenge(r, @key.public, tbs)
    s = rem(r_scalar + k * Ed25519Points.scalar(@key.private), Ed25519Points.l())
    r <> <<s::little-256>>
  end

  describe "AC1: ACCUSE in the single-signer carrier" do
    test "a verified carrier's body defect is exit 7 with one finding; unverified, it is never read" do
      if Ed25519Oracle.verifies?() do
        no_issuer = CBOR.encode!(%{0 => 1, 16 => {:text, "slice 144"}})

        assert verify(carrier(no_issuer, &signed/1)) ==
                 {:error, 7,
                  {:accuse_single_signed_nonconforming, [nonconforming: :issuer_missing]}}

        # Under the wrong `typ` (key 0 of another schema) and without key 1: B7 runs first and
        # stops the judging, so the one finding is B7's.
        both = CBOR.encode!(%{0 => 2, 16 => {:text, "slice 144"}})

        assert verify(carrier(both, &signed/1)) ==
                 {:error, 7,
                  {:accuse_single_signed_nonconforming, [nonconforming: :typ_schema_mismatch]}}

        # A codec defect (D16) in signed bytes is `_noncanonical`.
        good = CBOR.encode!(%{0 => 1, 1 => {:text, "trinity:test.invalid"}, 16 => {:text, "abc"}})
        cf = :binary.replace(good, "abc", "​")
        assert byte_size(cf) == byte_size(good)

        assert verify(carrier(cf, &signed/1)) ==
                 {:error, 7,
                  {:accuse_single_signed_noncanonical, [nonconforming: :text_format_control]}}

        # The same bodies under a signature that does not verify: exit 1, the body unread.
        for body <- [no_issuer, both, cf] do
          bad = fn tbs -> signed(tbs <> "x") end
          assert verify(carrier(body, bad)) == {:error, 1, :signature_invalid}
        end
      else
        IO.puts("verdicts_test: Ed25519 refused on this runtime; AC1's signed cases not run")
      end
    end
  end

  describe "AC3: the Ed25519 key rule" do
    test "every key the rule names is refused, and generated keys are not" do
      identity = Ed25519Points.encode({0, 1})
      t8 = Ed25519Points.order8()
      a = Ed25519Points.multiply(Ed25519Points.scalar(@key.private), Ed25519Points.base())

      refused = %{
        "identity" => identity,
        "(0, -1)" => <<0xEC>> <> :binary.copy(<<0xFF>>, 30) <> <<0x7F>>,
        "order 4" => :binary.copy(<<0>>, 32),
        "order 8" => Ed25519Points.encode(t8),
        "mixed order" => Ed25519Points.encode(Ed25519Points.add(a, t8)),
        "x = 0, sign bit set" => <<1>> <> :binary.copy(<<0>>, 30) <> <<0x80>>,
        "no point" => <<2>> <> :binary.copy(<<0>>, 31),
        "y = p + 1" => <<0xEE>> <> :binary.copy(<<0xFF>>, 30) <> <<0x7F>>
      }

      for {name, key} <- refused, do: refute(Ed25519.valid_key?(key), name)
      assert Ed25519Points.encode(a) == @key.public

      # Keys from random seeds by the oracle, not `:crypto`, which refuses Ed25519 in FIPS mode.
      for _ <- 1..200 do
        seed = :crypto.strong_rand_bytes(32)

        pub =
          Ed25519Points.encode(
            Ed25519Points.multiply(Ed25519Points.scalar(seed), Ed25519Points.base())
          )

        assert Ed25519.valid_key?(pub)
      end
    end

    test "the identity key with R the identity and S = 0 is key_invalid, though the equation holds" do
      identity = Ed25519Points.encode({0, 1})
      body = CBOR.encode!(%{0 => 1, 1 => {:text, "trinity:test.invalid"}})
      bytes = carrier(body, fn _ -> identity <> :binary.copy(<<0>>, 32) end, identity)
      assert verify(bytes, identity) == {:error, 1, :key_invalid}
    end
  end

  describe "AC4: the Ed25519 signature rule" do
    # The R and S checks are the profile's, decided before the runtime is asked, so a signature
    # they refuse is signature_invalid on every runtime, FIPS mode included. A mixed-order R passes
    # them (it is not of small order) and is refused by the equation, which needs the runtime.
    test "R and S the rule refuses, each signature_invalid, made by the key's holder" do
      body = CBOR.encode!(%{0 => 1, 1 => {:text, "trinity:test.invalid"}})
      t8 = Ed25519Points.order8()
      l = Ed25519Points.l()
      r = 0x1234_5678_9ABC
      r_point = Ed25519Points.multiply(r, Ed25519Points.base())
      ed25519? = Ed25519Oracle.verifies?()

      mixed = verify(carrier(body, &chosen_r(Ed25519Points.add(r_point, t8), r, &1)))

      if ed25519?,
        do: assert(mixed == {:error, 1, :signature_invalid}),
        else: assert(mixed == {:error, 5, :alg_unavailable})

      cases = %{
        "R the identity, S = k * a" => fn tbs -> chosen_r({0, 1}, 0, tbs) end,
        "R of order 8, S = k * a" => fn tbs -> chosen_r(t8, 0, tbs) end,
        "R the identity as y = p + 1" => fn tbs ->
          r = <<0xEE>> <> :binary.copy(<<0xFF>>, 30) <> <<0x7F>>
          k = Ed25519Points.challenge(r, @key.public, tbs)
          r <> <<rem(k * Ed25519Points.scalar(@key.private), l)::little-256>>
        end,
        "R with x = 0 and the sign bit set" => fn tbs ->
          <<_::binary-32, s::binary-32>> = chosen_r(r_point, r, tbs)
          <<1>> <> :binary.copy(<<0>>, 30) <> <<0x80>> <> s
        end,
        "S + L" => fn tbs ->
          <<rb::binary-32, s::little-256>> = chosen_r(r_point, r, tbs)
          rb <> <<s + l::little-256>>
        end
      }

      for {name, sig} <- cases,
          do: assert(verify(carrier(body, sig)) == {:error, 1, :signature_invalid}, name)

      # The control: R chosen honestly verifies, where the runtime does Ed25519.
      honest = verify(carrier(body, &chosen_r(r_point, r, &1)))

      if ed25519?,
        do: assert({:ok, %{verdict_code: :claim}} = honest),
        else: assert(honest == {:error, 5, :alg_unavailable})
    end
  end
end
