# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.COSETest do
  @moduledoc """
  Slice 138, AC6 and AC7, and the parts of AC8 that need no signature: the key thumbprint, the
  header rules, the unprotected header, ToBeSigned, and what `verify/2` answers when it cannot
  judge. None of it needs a runtime that signs ML-DSA-87, so it runs on every leg.
  """

  use ExUnit.Case, async: true

  alias Trinity.N6.{CBOR, COSE, Profile}
  alias Trinity.TestSupport.{MLDSA87Oracle, N6Vectors}

  @typ "application/vnd.example.test.v1+cose"

  setup_all do
    key = N6Vectors.acvp_key()
    %{key: key, kid: COSE.thumbprint(key.public), table: N6Vectors.typ_table()}
  end

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
  end

  describe "AC7: the header rules" do
    test "every positive header decodes, and the builder makes exactly the plain one", %{
      kid: kid,
      table: table
    } do
      for path <- Path.wildcard(Path.join(N6Vectors.root(), "header/positive/*.cbor")) do
        assert {:ok, %{kid: ^kid}} = COSE.decode_protected(File.read!(path), table), path
      end

      plain = File.read!(Path.join(N6Vectors.root(), "header/positive/alg_kid_typ.cbor"))
      assert COSE.protected_header(kid, @typ) == plain
    end

    test "every negative header is refused with its code", %{table: table} do
      vectors = N6Vectors.negative("header")
      assert length(vectors) >= 17

      for {defect, id, bytes, code} <- vectors do
        assert COSE.decode_protected(bytes, table) == {:error, code}, "#{defect}/#{id}"
        assert Profile.exit_of(code) == 1
      end
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

      assert COSE.verify(parts, keys: fn _ -> {:ok, key.public} end, typ: table) ==
               {:error, 1, :kid_not_thumbprint}
    end

    test "a signature of the wrong size is a malformed carrier", %{
      key: key,
      kid: kid,
      table: table
    } do
      parts = %{protected: COSE.protected_header(kid, @typ), payload: "x", signature: <<0>>}

      assert COSE.verify(parts, keys: fn _ -> {:ok, key.public} end, typ: table) ==
               {:error, 1, :carrier_malformed}
    end

    test "a runtime without ML-DSA-87 answers no trust, never a crash; one with it judges the signature",
         %{key: key, kid: kid, table: table} do
      parts = %{
        protected: COSE.protected_header(kid, @typ),
        payload: "x",
        signature: :binary.copy(<<0>>, 4627)
      }

      answer = COSE.verify(parts, keys: fn _ -> {:ok, key.public} end, typ: table)

      if MLDSA87Oracle.signs?() do
        assert answer == {:error, 1, :signature_invalid}
      else
        assert answer == {:error, 5, :alg_unavailable}

        assert COSE.sign("x", @typ, %{public: key.public, private: {:seed, key.seed}}) ==
                 {:error, :alg_unavailable}
      end
    end
  end
end
