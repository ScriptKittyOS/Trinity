# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.COSESigningTest do
  @moduledoc """
  Slice 138, AC8: ML-DSA-87 signing and verification of a Sign1, where the runtime signs. Tagged
  `:mldsa87_runtime` (slice 137), so it runs in the `fips` job's mode-off step and on a local
  OpenSSL 3.5 runtime, and is excluded, by the printed decision, everywhere else.

  The key is NIST ACVP's published keyGen case (slice 137 pins it), so no key of this tree's is
  published: its 32-byte seed and its expanded secret key are two forms of one key.

  Slice 139, AC4: an ML-DSA-87 Sign1 in the single-signer carrier verifies, at both entry points.
  """

  use ExUnit.Case, async: true

  alias Trinity.N6.{Carrier, COSE}
  alias Trinity.TestSupport.N6Vectors

  @moduletag :mldsa87_runtime

  @typ "application/vnd.example.test.v1+cose"
  @typ_scitt "application/vnd.example.scitt-test.v1+cose"

  setup_all do
    key = N6Vectors.acvp_key()
    kid = COSE.thumbprint(key.public)
    keys = fn k -> if k == kid, do: {:ok, %{alg: -50, public: key.public}}, else: :error end
    %{key: key, opts: [keys: keys, typ: N6Vectors.typ_table()]}
  end

  test "signed with the seed and with the expanded key, both verify", %{key: key, opts: opts} do
    for private <- [{:seed, key.seed}, key.expanded] do
      assert {:ok, parts} =
               COSE.sign("a statement", @typ, %{public: key.public, private: private})

      assert byte_size(parts.signature) == 4627
      assert {:ok, %{exit: 0, verdict_code: :claim, typ: @typ}} = COSE.verify(parts, opts)
    end
  end

  test "one flipped byte in the protected header, the payload or the signature is invalid", %{
    key: key,
    opts: opts
  } do
    {:ok, parts} =
      COSE.sign("a statement", @typ, %{public: key.public, private: {:seed, key.seed}})

    # In the protected header: the map head, the alg value (byte 3 of a3 01 38 31) and the typ's
    # last byte. A byte inside the kid names another key, which is no trust, tested below.
    positions = fn
      :protected, bytes -> [0, 3, byte_size(bytes) - 1]
      _field, bytes -> [0, div(byte_size(bytes), 2), byte_size(bytes) - 1]
    end

    for field <- [:protected, :payload, :signature],
        at <- positions.(field, Map.fetch!(parts, field)) do
      bytes = Map.fetch!(parts, field)
      <<pre::binary-size(^at), b, post::binary>> = bytes
      flipped = Map.put(parts, field, <<pre::binary, Bitwise.bxor(b, 1), post::binary>>)

      assert {:error, 1, _code} = COSE.verify(flipped, opts), "#{field} byte #{at}"
    end
  end

  test "both exchange forms carry the same parts, and each verifies", %{key: key, opts: opts} do
    {:ok, parts} =
      COSE.sign("a statement", @typ, %{public: key.public, private: {:seed, key.seed}})

    assert {:ok, detached} = COSE.parse(COSE.render(parts, :detached), :detached, parts.payload)
    assert {:ok, attached} = COSE.parse(COSE.render(parts, :attached_tagged), :attached_tagged)
    assert detached == parts and attached == parts
    assert {:ok, _} = COSE.verify(detached, opts)
    assert {:ok, _} = COSE.verify(attached, opts)
  end

  test "a SCITT-renderable typ carries the CWT claims, protected", %{key: key, opts: opts} do
    {:ok, parts} =
      COSE.sign("a statement", @typ_scitt, %{public: key.public, private: {:seed, key.seed}},
        cwt: {"iss.invalid", "sub"}
      )

    assert {:ok, %{exit: 0}} = COSE.verify(parts, opts)

    assert {:ok, %{cwt: %{iss: "iss.invalid", sub: "sub"}}} =
             COSE.decode_protected(parts.protected, opts[:typ])
  end

  test "a kid nobody registered is no trust, including one flipped inside a signed header", %{
    key: key,
    opts: opts
  } do
    {:ok, parts} =
      COSE.sign("a statement", @typ, %{public: key.public, private: {:seed, key.seed}})

    assert COSE.verify(parts, Keyword.put(opts, :keys, fn _ -> :error end)) ==
             {:error, 5, :policy_stale_or_unknown_key}

    # The kid's bytes start after a3 01 38 31 04 58 30.
    <<pre::binary-size(7), b, post::binary>> = parts.protected
    flipped = %{parts | protected: <<pre::binary, Bitwise.bxor(b, 1), post::binary>>}
    assert COSE.verify(flipped, opts) == {:error, 5, :policy_stale_or_unknown_key}
  end

  test "slice 139: in the single-signer carrier, it verifies at nss and at commercial", %{
    key: key,
    opts: opts
  } do
    key = %{alg: -50, public: key.public, private: {:seed, key.seed}}

    # Since slice 140 the carrier reads the body it covers: an N6 map naming its issuer (key 1).
    body =
      Trinity.N6.CBOR.encode!(%{
        0 => 1,
        1 => {:text, "trinity:test.invalid"},
        16 => {:text, "a statement"}
      })

    {:ok, parts} = COSE.sign(body, @typ, key)

    carrier = Carrier.encode(parts)
    assert Carrier.decode(carrier) == {:ok, parts}

    for entry <- [:nss, :commercial] do
      assert {:ok, %{exit: 0, verdict_code: :claim}} =
               Carrier.verify(carrier, Keyword.put(opts, :entry, entry))
    end

    # Slice 139's payload, bare text: its signature verifies, and the carrier refuses what it covers.
    # Since slice 144 a codec defect in verified bytes is the signer's act: exit 7, `_noncanonical`.
    {:ok, bare} = COSE.sign("a statement", @typ, key)
    assert {:ok, %{verdict_code: :claim}} = COSE.verify(bare, opts)

    assert Carrier.verify(Carrier.encode(bare), opts) ==
             {:error, 7, {:accuse_single_signed_noncanonical, [nonconforming: :trailing_bytes]}}
  end
end
