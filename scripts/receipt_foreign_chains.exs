# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Writes the receipt chains under `test/fixtures/receipts/` (slice 139): exported chains signed under
# algorithms a runtime may refuse, so the verifier's answer on such a runtime can be tested there.
#
#     mix run --no-start scripts/receipt_foreign_chains.exs test/fixtures/receipts
#
# Run it on a runtime that signs both algorithms (OTP 28.5.0.8 with OpenSSL 3.5.9, FIPS mode off).
# The keys are published test keys, never a key of this tree's: RFC 8032 section 7.1 test 1 for
# Ed25519, and NIST ACVP's ML-DSA-87 keyGen case (`priv/kat/acvp/`, slice 137) for ML-DSA-87.
#
# Ed25519 is deterministic, so its two chains come out the same on every run. ML-DSA-87 signing is
# hedged, so its two chains differ in their signature bytes from run to run; the checked-in files
# are one run's output, and nothing compares them with a rerun.
#
# Each algorithm gets two chains: `signed` (one decision receipt, signed) and `checkpoint` (one query
# receipt, unsigned, under one signed checkpoint), because the verifier checks a row's signature and
# a checkpoint's signature at two different places.

alias Trinity.Receipts.{Envelope, Signer}

defmodule ForeignChains do
  @at "2026-10-20T00:00:00.000000Z"
  @wall 1_792_454_400_000

  def run([root]) do
    acvp = "priv/kat/acvp/mldsa87_keygen.json" |> File.read!() |> JSON.decode!()

    keys = %{
      "ed25519" => %{
        public: h("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"),
        sign: fn bytes ->
          priv = h("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
          :crypto.sign(:eddsa, :none, bytes, [priv, :ed25519])
        end
      },
      "mldsa87" => %{
        public: Base.decode16!(acvp["pk"]),
        sign: fn bytes ->
          :crypto.sign(:mldsa87, :none, bytes, {:seed, Base.decode16!(acvp["seed"])})
        end
      }
    }

    File.mkdir_p!(root)

    for {alg, key} <- keys do
      registry = [registry_row(alg, key.public)]
      key_id = hd(registry)["key_id"]
      scheme = "receipt_v3_" <> alg

      signed = %{
        "receipts" => [row(alg, scheme, key_id, 1, nil, "decision", key.sign)],
        "checkpoints" => [],
        "registry" => registry
      }

      query = row(alg, scheme, key_id, 1, nil, "query", key.sign)

      checkpoint = %{
        "receipts" => [query],
        "checkpoints" => [checkpoint(alg, scheme, key_id, query, key.sign)],
        "registry" => registry
      }

      write(root, "#{alg}_signed.json", export(alg, "signed", signed))
      write(root, "#{alg}_checkpoint.json", export(alg, "checkpoint", checkpoint))
    end
  end

  defp export(alg, name, map) do
    Map.merge(map, %{
      "format" => "trinity-receipts-export/1",
      "chain_scope" => scope(alg, name),
      "exported_at" => @at
    })
  end

  defp scope(alg, _name), do: "fixture:" <> alg

  defp row(alg, scheme, key_id, seq, prev_hash, kind, sign) do
    body = %{
      "scheme" => scheme,
      "seq" => seq,
      "chain_scope" => scope(alg, nil),
      "prev_hash" => prev_hash,
      "kind" => kind,
      "subject" => %{"fixture" => "slice 139"},
      "decision" => if(kind == "decision", do: %{"outcome" => "allow", "basis" => "fixture"}),
      "fingerprint" => nil,
      "at" => @at,
      "key_id" => key_id,
      "clock" => %{"wall" => @wall, "counter" => seq - 1, "node" => "fixture"}
    }

    payload = Envelope.canonical(body)
    bytes = Envelope.pae(Envelope.receipt_type(scheme), payload)

    %{
      "chain_scope" => body["chain_scope"],
      "seq" => seq,
      "prev_hash" => prev_hash,
      "receipt_hash" => Envelope.hash(bytes),
      "scheme" => scheme,
      "kind" => kind,
      "signed_payload" => payload,
      "signature_b64" => if(kind == "query", do: nil, else: Base.encode64(sign.(bytes))),
      "key_id" => key_id,
      "meta" => %{}
    }
  end

  defp checkpoint(alg, scheme, key_id, tail, sign) do
    body = %{
      "scheme" => scheme,
      "chain_scope" => scope(alg, nil),
      "boot_receipt_hash" => nil,
      "first_seq" => tail["seq"],
      "last_seq" => tail["seq"],
      "tail_hash" => tail["receipt_hash"],
      "key_id" => key_id,
      "reason" => "fixture",
      "at" => @at
    }

    payload = Envelope.canonical(body)
    bytes = Envelope.pae(Envelope.checkpoint_type(scheme), payload)

    %{
      "chain_scope" => body["chain_scope"],
      "boot_receipt_hash" => nil,
      "first_seq" => tail["seq"],
      "last_seq" => tail["seq"],
      "tail_hash" => tail["receipt_hash"],
      "scheme" => scheme,
      "signed_payload" => payload,
      "signature_b64" => Base.encode64(sign.(bytes)),
      "key_id" => key_id,
      "reason" => "fixture"
    }
  end

  # The registry row as `Trinity.Receipts.KeyCustody` writes one (slice 024).
  defp registry_row(alg, pub) do
    impl = Signer.impl(String.to_existing_atom(alg))
    jwk = impl.jwk(pub)

    {key_id, kid_scheme} =
      case jwk do
        nil -> {:crypto.hash(:sha256, pub) |> Base.url_encode64(padding: false), "sha256-raw"}
        jwk -> {Signer.thumbprint(jwk), "rfc7638"}
      end

    %{
      "key_id" => key_id,
      "kid_scheme" => kid_scheme,
      "algorithm" => alg,
      "scheme" => "receipt_v3_" <> alg,
      "jwk" => jwk,
      "public_key_b64" => Base.encode64(pub),
      "fingerprint" => :crypto.hash(:sha256, pub) |> Base.encode16(case: :lower),
      "valid_from" => @at,
      "status" => "active",
      "custody" => "file"
    }
  end

  defp write(root, name, map), do: File.write!(Path.join(root, name), JSON.encode!(map) <> "\n")

  defp h(hex), do: Base.decode16!(hex, case: :lower)
end

ForeignChains.run(System.argv())
