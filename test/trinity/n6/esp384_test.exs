# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.ESP384Test do
  @moduledoc """
  Slice 140, AC2: ESP384 (-51) under N6, the publisher's Decision of 2026-10-20, point 1. ECDSA on
  P-384 with SHA-384 is on every runtime this suite runs on, FIPS mode included, so nothing here
  branches; the module says which mode it ran in.

  The thumbprint is checked twice: against `Trinity.N6.EC2`, and against `sha384sum` run outside
  Elixir over the 107 bytes written to a file, so the expected value is no Elixir code's opinion.
  """

  use ExUnit.Case, async: true

  alias Trinity.N6.{COSE, EC2}
  alias Trinity.TestSupport.N6Vectors

  @typ "application/vnd.example.test-esp384.v1+cose"
  @tmp "tmp/esp384_test"

  setup_all do
    IO.puts("esp384_test: ESP384 signs and verifies with fips #{:crypto.info_fips()}")
    key = N6Vectors.rfc6979_p384_key()
    kid = COSE.thumbprint(-51, key.public)
    keys = fn k -> if k == kid, do: {:ok, %{alg: -51, public: key.public}}, else: :error end
    %{key: key, kid: kid, opts: [keys: keys, typ: N6Vectors.typ_table(), entry: :commercial]}
  end

  describe "the thumbprint" do
    for id <- ["rfc6979_a26_p384", "p384_x_leading_zero"] do
      test "#{id}: kid is SHA-384 over exactly the 107-byte EC2 input, as sha384sum says" do
        root = N6Vectors.root()
        pub = File.read!(Path.join(root, "thumbprint/#{unquote(id)}.pub"))
        kid = File.read!(Path.join(root, "thumbprint/#{unquote(id)}.kid"))
        <<4, x::binary-size(48), y::binary-size(48)>> = pub

        input = <<0xA4, 1, 2, 0x20, 2, 0x21, 0x58, 0x30>> <> x <> <<0x22, 0x58, 0x30>> <> y
        assert byte_size(input) == 107
        assert EC2.thumbprint_input(x, y) == input
        assert COSE.thumbprint(-51, pub) == kid

        File.mkdir_p!(@tmp)
        path = Path.join(@tmp, unquote(id) <> ".in")
        File.write!(path, input)
        {out, 0} = System.cmd("sha384sum", [path])
        assert out |> String.split() |> hd() == Base.encode16(kid, case: :lower)
      end
    end

    test "the leading-zero key keeps its zero byte" do
      pub = File.read!(Path.join(N6Vectors.root(), "thumbprint/p384_x_leading_zero.pub"))
      assert <<4, 0, _::binary>> = pub

      <<4, x::binary-size(48), y::binary-size(48)>> = pub
      stripped = binary_part(x, 1, 47)

      # What an implementation that strips leading zeros would hash instead.
      wrong =
        :crypto.hash(
          :sha384,
          <<0xA4, 1, 2, 0x20, 2, 0x21, 0x58, 0x2F>> <> stripped <> <<0x22, 0x58, 0x30>> <> y
        )

      refute COSE.thumbprint(-51, pub) == wrong
    end
  end

  describe "signing and verifying" do
    test "signs a 96-byte r || s that verifies, and n - s verifies too", %{key: key, opts: opts} do
      assert {:ok, parts} = COSE.sign("a statement", @typ, key)
      assert byte_size(parts.signature) == 96
      assert {:ok, %{exit: 0, verdict_code: :claim}} = COSE.verify(parts, opts)

      other = %{parts | signature: EC2.negate_s(parts.signature)}
      refute other.signature == parts.signature
      assert {:ok, %{exit: 0, verdict_code: :claim}} = COSE.verify(other, opts)
    end

    test "one flipped byte in the header, the payload or the signature is invalid", %{
      key: key,
      opts: opts
    } do
      {:ok, parts} = COSE.sign("a statement", @typ, key)

      # The last protected byte is inside `typ`; a byte inside `kid` would be an unknown key (5).
      for field <- [:protected, :payload, :signature] do
        bin = Map.fetch!(parts, field)
        at = byte_size(bin) - 1
        <<a::binary-size(^at), b>> = bin

        assert {:error, 1, _code} =
                 COSE.verify(%{parts | field => a <> <<Bitwise.bxor(b, 1)>>}, opts),
               "#{field}"
      end
    end

    test "DER, or 95 or 97 bytes, is signature_encoding", %{key: key, opts: opts} do
      {:ok, parts} = COSE.sign("a statement", @typ, key)
      der = EC2.to_der(parts.signature)
      assert byte_size(der) in 101..104

      for sig <- [der, binary_part(parts.signature, 0, 95), parts.signature <> <<0>>] do
        assert COSE.verify(%{parts | signature: sig}, opts) == {:error, 1, :signature_encoding}
      end
    end

    test "at nss, -51 is alg_not_permitted", %{key: key, opts: opts} do
      {:ok, parts} = COSE.sign("a statement", @typ, key)

      assert COSE.verify(parts, Keyword.put(opts, :entry, :nss)) ==
               {:error, 1, :alg_not_permitted}
    end

    test "a key registered under another algorithm is alg_not_permitted", %{key: key, kid: kid} do
      {:ok, parts} = COSE.sign("a statement", @typ, key)

      for alg <- [-19, -50] do
        keys = fn k -> if k == kid, do: {:ok, %{alg: alg, public: key.public}}, else: :error end
        opts = [keys: keys, typ: N6Vectors.typ_table(), entry: :commercial]
        assert COSE.verify(parts, opts) == {:error, 1, :alg_not_permitted}, "registered #{alg}"
      end
    end

    test "a compressed point, a P-256 key and a point off the curve are key_invalid", %{
      key: key,
      kid: kid
    } do
      {:ok, parts} = COSE.sign("a statement", @typ, key)
      <<4, x::binary-size(48), y::binary-size(48)>> = key.public
      <<yn::unsigned-size(384)>> = y
      root = N6Vectors.root()

      for pub <- [
            <<2 + rem(yn, 2)>> <> x,
            File.read!(Path.join(root, "thumbprint/rfc6979_a25_p256.pub")),
            <<4>> <> x <> <<yn + 1::unsigned-size(384)>>
          ] do
        keys = fn k -> if k == kid, do: {:ok, %{alg: -51, public: pub}}, else: :error end
        opts = [keys: keys, typ: N6Vectors.typ_table(), entry: :commercial]
        assert COSE.verify(parts, opts) == {:error, 1, :key_invalid}
      end
    end
  end

  test "DER and r || s convert both ways, for signatures of every length OTP makes", %{key: key} do
    for i <- 1..200 do
      der = :crypto.sign(:ecdsa, :sha384, "m#{i}", [key.private, :secp384r1])
      assert {:ok, raw} = EC2.from_der(der)
      assert byte_size(raw) == 96
      assert EC2.to_der(raw) == der
    end

    assert EC2.from_der(<<0x30, 0x02, 0x02, 0x00>>) == :error
    assert EC2.from_der(:binary.copy(<<0>>, 96)) == :error
  end
end
