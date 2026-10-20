# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.COSETest do
  @moduledoc """
  Slice 138, AC6 and AC7, and the parts of AC8 that need no signature: the key thumbprint, the
  header rules, the unprotected header, ToBeSigned, and what `verify/2` answers when it cannot
  judge. None of it needs a runtime that signs ML-DSA-87, so it runs on every leg.

  Slice 139, AC1 to AC3: the OKP thumbprint, the header rules for Ed25519 and the entry points, and
  Ed25519 signing, which is deterministic and needs no special runtime but is refused in FIPS mode,
  so each leg takes the branch its runtime allows and the module says which.
  """

  use ExUnit.Case, async: true

  alias Trinity.N6.{CBOR, COSE, Profile}
  alias Trinity.TestSupport.{Ed25519Oracle, MLDSA87Oracle, N6Vectors}

  @typ "application/vnd.example.test.v1+cose"
  @typ_ed "application/vnd.example.test-ed25519.v1+cose"
  @typ_esp "application/vnd.example.test-esp384.v1+cose"

  setup_all do
    key = N6Vectors.acvp_key()
    ed = N6Vectors.rfc8032_key()

    IO.puts(
      "cose_test: Ed25519 #{if Ed25519Oracle.verifies?(), do: "verifies", else: "is refused"} " <>
        "on this runtime (fips #{:crypto.info_fips()})"
    )

    %{
      key: key,
      kid: COSE.thumbprint(key.public),
      ed: ed,
      ed_kid: COSE.thumbprint(-19, ed.public),
      ec_kid: COSE.thumbprint(-51, N6Vectors.rfc6979_p384_key().public),
      table: N6Vectors.typ_table()
    }
  end

  defp mldsa(key), do: fn _ -> {:ok, %{alg: -50, public: key.public}} end

  describe "AC6: the thumbprint" do
    test "kid for ACVP's published key is SHA-384 over exactly the RFC 9679 input", %{key: key} do
      pub = File.read!(Path.join(N6Vectors.root(), "thumbprint/acvp_mldsa87_tg3_tc51.pub"))
      kid = File.read!(Path.join(N6Vectors.root(), "thumbprint/acvp_mldsa87_tg3_tc51.kid"))
      assert pub == key.public

      input = <<0xA3, 0x01, 0x07, 0x03, 0x38, 0x31, 0x20, 0x59, 0x0A, 0x20>> <> pub
      assert COSE.thumbprint(pub) == kid
      assert :crypto.hash(:sha384, input) == kid

      # The same input is the RFC 8949 section 4.2.1 encoding of {1: 7, 3: -50, -1: pub}, but
      # N6 cannot build it (key -1 is outside its keys), which is why the prefix is fixed by hand.
      assert CBOR.encode(%{1 => 7, 3 => -50}) == {:ok, <<0xA2, 0x01, 0x07, 0x03, 0x38, 0x31>>}
    end

    test "slice 139, AC1: the OKP kid for RFC 8032's test key is SHA-384 over exactly its input",
         %{
           ed: ed
         } do
      pub = File.read!(Path.join(N6Vectors.root(), "thumbprint/rfc8032_test1_ed25519.pub"))
      kid = File.read!(Path.join(N6Vectors.root(), "thumbprint/rfc8032_test1_ed25519.kid"))
      assert pub == ed.public

      # {1: 1, -1: 6, -2: x}: kty OKP, crv Ed25519 (RFC 9053 section 7.1), keys 0x01, 0x20, 0x21.
      input = <<0xA3, 0x01, 0x01, 0x20, 0x06, 0x21, 0x58, 0x20>> <> pub
      assert COSE.thumbprint(-19, pub) == kid
      assert :crypto.hash(:sha384, input) == kid
    end
  end

  describe "AC7: the header rules" do
    test "every positive header decodes at commercial, and the builder makes exactly each", %{
      kid: kid,
      ed_kid: ed_kid,
      ec_kid: ec_kid,
      table: table
    } do
      positives = Path.wildcard(Path.join(N6Vectors.root(), "header/positive/*.cbor"))
      assert length(positives) == 5

      for path <- positives do
        assert {:ok, %{kid: k}} = COSE.decode_protected(File.read!(path), table, :commercial),
               path

        assert k in [kid, ed_kid, ec_kid]
      end

      # Slice 140: no `typ` names an algorithm, so -19 under the ML-DSA-87 test `typ` decodes; the
      # key's registration decides (the cose samples).
      any =
        File.read!(Path.join(N6Vectors.root(), "header/positive/ed25519_alg_under_any_typ.cbor"))

      assert COSE.protected_header(ed_kid, @typ, nil, -19) == any

      esp = File.read!(Path.join(N6Vectors.root(), "header/positive/esp384_alg_kid_typ.cbor"))
      assert COSE.protected_header(ec_kid, @typ_esp, nil, -51) == esp

      plain = File.read!(Path.join(N6Vectors.root(), "header/positive/alg_kid_typ.cbor"))
      assert COSE.protected_header(kid, @typ) == plain

      ed = File.read!(Path.join(N6Vectors.root(), "header/positive/ed25519_alg_kid_typ.cbor"))
      assert COSE.protected_header(ed_kid, @typ_ed, nil, -19) == ed
    end

    test "every negative header is refused with its code, at either entry point", %{table: table} do
      vectors = N6Vectors.negative("header")
      assert length(vectors) >= 19

      for {defect, id, bytes, code} <- vectors, entry <- [:nss, :commercial] do
        assert COSE.decode_protected(bytes, table, entry) == {:error, code},
               "#{defect}/#{id} at #{entry}"

        assert Profile.exit_of(code) == 1
      end
    end

    test "slice 139, AC2: -19 decodes at commercial and is refused at nss, the default", %{
      ed_kid: ed_kid,
      table: table
    } do
      ed = COSE.protected_header(ed_kid, @typ_ed, nil, -19)

      assert {:ok, %{alg: -19, kid: ^ed_kid, entry: %{carrier: :single}}} =
               COSE.decode_protected(ed, table, :commercial)

      assert COSE.decode_protected(ed, table, :nss) == {:error, :alg_not_permitted}
      assert COSE.decode_protected(ed, table) == {:error, :alg_not_permitted}
    end

    test "the unprotected header must be empty", %{kid: kid} do
      p = COSE.protected_header(kid, @typ)
      sig = :binary.copy(<<0>>, 4627)
      parts = %{protected: p, payload: "x", signature: sig}

      assert {:ok, ^parts} = COSE.parse(COSE.render(parts, :detached), :detached, "x")
      assert {:ok, ^parts} = COSE.parse(COSE.render(parts, :attached_tagged), :attached_tagged)

      sign1 = fn unprotected, payload ->
        CBOR.encode!([{:bytes, p}, unprotected, payload, {:bytes, sig}])
      end

      for label <- [7, 9, 11, 12] do
        assert COSE.parse(sign1.(%{label => {:bytes, "c"}}, nil), :detached, "x") ==
                 {:error, :countersignature_forbidden}
      end

      for label <- [1, 4, 16] do
        assert COSE.parse(sign1.(%{label => 0}, nil), :detached, "x") ==
                 {:error, :header_not_protected}
      end

      assert COSE.parse(sign1.(%{5 => 0}, nil), :detached, "x") ==
               {:error, :unprotected_forbidden}

      # A negative label is refused by the codec's key rule; the only map in a Sign1 is this one.
      negative =
        <<0x84, 0x58, byte_size(p)>> <> p <> <<0xA1, 0x20, 0x00, 0xF6, 0x59, 4627::16>> <> sig

      assert COSE.parse(negative, :detached, "x") == {:error, :unprotected_forbidden}

      assert COSE.parse(sign1.(%{}, {:bytes, "x"}), :detached, "x") ==
               {:error, :carrier_malformed}

      assert COSE.parse(sign1.(%{}, nil), :attached_tagged) == {:error, :carrier_malformed}

      assert COSE.parse(<<0xD2>> <> sign1.(%{}, nil), :attached_tagged) ==
               {:error, :carrier_malformed}
    end
  end

  describe "AC8, without signing" do
    test "ToBeSigned is RFC 9052's Sig_structure with an empty external_aad", %{kid: kid} do
      p = COSE.protected_header(kid, @typ)

      assert COSE.to_be_signed(p, "payload") ==
               <<0x84, 0x6A, "Signature1", 0x58, byte_size(p)>> <> p <> <<0x40, 0x47, "payload">>
    end

    test "an unknown kid is no trust (5), before any signature is checked", %{
      kid: kid,
      table: table
    } do
      parts = %{
        protected: COSE.protected_header(kid, @typ),
        payload: "x",
        signature: :binary.copy(<<0>>, 4627)
      }

      assert COSE.verify(parts, keys: fn _ -> :error end, typ: table) ==
               {:error, 5, :policy_stale_or_unknown_key}
    end

    test "a registered key whose thumbprint is not the kid is refused", %{key: key, table: table} do
      other_kid = :crypto.hash(:sha384, "not this key")

      parts = %{
        protected: COSE.protected_header(other_kid, @typ),
        payload: "x",
        signature: :binary.copy(<<0>>, 4627)
      }

      assert COSE.verify(parts, keys: mldsa(key), typ: table) ==
               {:error, 1, :kid_not_thumbprint}
    end

    test "a signature of the wrong size is a malformed carrier", %{
      key: key,
      kid: kid,
      table: table
    } do
      parts = %{protected: COSE.protected_header(kid, @typ), payload: "x", signature: <<0>>}

      assert COSE.verify(parts, keys: mldsa(key), typ: table) ==
               {:error, 1, :carrier_malformed}
    end

    test "a runtime without ML-DSA-87 answers no trust, never a crash; one with it judges the signature",
         %{key: key, kid: kid, table: table} do
      parts = %{
        protected: COSE.protected_header(kid, @typ),
        payload: "x",
        signature: :binary.copy(<<0>>, 4627)
      }

      answer = COSE.verify(parts, keys: mldsa(key), typ: table)

      if MLDSA87Oracle.signs?() do
        assert answer == {:error, 1, :signature_invalid}
      else
        assert answer == {:error, 5, :alg_unavailable}

        assert COSE.sign("x", @typ, %{public: key.public, private: {:seed, key.seed}}) ==
                 {:error, :alg_unavailable}
      end
    end
  end

  describe "slice 139, AC3: Ed25519" do
    # Slice 140: `alg_not_permitted`, the publisher's Decision of 2026-10-20 (point 1, the algorithm
    # check); slice 139 answered `kid_not_thumbprint` here.
    test "a key registered under another algorithm than the header's is alg_not_permitted", %{
      key: key,
      ed: ed,
      ed_kid: ed_kid,
      kid: kid,
      table: table
    } do
      # An ML-DSA-87 key under a -19 header, and an Ed25519 key under a -50 header.
      ed_parts = %{
        protected: COSE.protected_header(ed_kid, @typ_ed, nil, -19),
        payload: "x",
        signature: :binary.copy(<<0>>, 64)
      }

      assert COSE.verify(ed_parts, keys: mldsa(key), typ: table, entry: :commercial) ==
               {:error, 1, :alg_not_permitted}

      ml_parts = %{
        protected: COSE.protected_header(kid, @typ),
        payload: "x",
        signature: :binary.copy(<<0>>, 4627)
      }

      ed_key = fn _ -> {:ok, %{alg: -19, public: ed.public}} end

      assert COSE.verify(ml_parts, keys: ed_key, typ: table, entry: :commercial) ==
               {:error, 1, :alg_not_permitted}
    end

    # Found by planting (PROOF, P5): with the sizes of -50 and -19 keys different, the size check
    # refuses a key of the other algorithm on its own, so the registration's algorithm is only
    # observable where the registration is wrong about its own key.
    test "a registration that names another algorithm is refused, even for bytes that would verify",
         %{ed: ed, ed_kid: ed_kid, table: table} do
      sample = File.read!(Path.join(N6Vectors.root(), "cose/sign1/ed25519_single.bin"))
      {:ok, parts} = Trinity.N6.Carrier.decode(sample)

      # The Ed25519 test key, registered as if it were an ML-DSA-87 key.
      wrong = fn k -> if k == ed_kid, do: {:ok, %{alg: -50, public: ed.public}}, else: :error end

      assert COSE.verify(parts, keys: wrong, typ: table, entry: :commercial) ==
               {:error, 1, :alg_not_permitted}
    end

    test "signs the sample's literal signature and verifies; one flipped byte is invalid; " <>
           "where FIPS mode refuses Ed25519, both answer alg_unavailable",
         %{ed: ed, ed_kid: ed_kid, table: table} do
      sample = File.read!(Path.join(N6Vectors.root(), "cose/sign1/ed25519_single.bin"))
      literal = binary_part(sample, byte_size(sample) - 64, 64)
      # {0: 1, 1: "trinity:test.invalid", 16: "slice 139"}, the sample's body since slice 140.
      payload =
        <<0xA3, 0x00, 0x01, 0x01, 0x74>> <>
          "trinity:test.invalid" <> <<0x10, 0x69>> <> "slice 139"

      keys = fn k -> if k == ed_kid, do: {:ok, %{alg: -19, public: ed.public}}, else: :error end
      opts = [keys: keys, typ: table, entry: :commercial]

      if Ed25519Oracle.verifies?() do
        assert {:ok, parts} = COSE.sign(payload, @typ_ed, ed)
        assert parts.signature == literal
        assert {:ok, %{exit: 0, verdict_code: :claim, typ: @typ_ed}} = COSE.verify(parts, opts)

        # The last protected byte is inside `typ`; a byte inside `kid` would be an unknown key (5).
        for field <- [:protected, :payload, :signature],
            at <- [0, byte_size(Map.fetch!(parts, field)) - 1] do
          flipped = Map.update!(parts, field, &flip(&1, at))
          assert {:error, 1, _code} = COSE.verify(flipped, opts), "#{field} byte #{at}"
        end
      else
        assert COSE.sign(payload, @typ_ed, ed) == {:error, :alg_unavailable}

        parts = %{
          protected: COSE.protected_header(ed_kid, @typ_ed, nil, -19),
          payload: payload,
          signature: literal
        }

        assert COSE.verify(parts, opts) == {:error, 5, :alg_unavailable}
      end
    end
  end

  defp flip(bin, at) do
    <<a::binary-size(^at), b, rest::binary>> = bin
    a <> <<Bitwise.bxor(b, 1)>> <> rest
  end
end
