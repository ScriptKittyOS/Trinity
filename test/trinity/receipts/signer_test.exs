# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.SignerTest do
  @moduledoc """
  Slice 024, G1 line 2: the signer seam, key custody and the registry. The selection rule
  is measured against `crypto:info_fips/0` on this runtime (`not_supported` here, `enabled`
  on the FIPS leg, where test/fips/receipts_test.exs asserts the other branch).
  """
  use ExUnit.Case, async: false

  alias Trinity.Receipts.{Envelope, KeyCustody, KeyRegistry, Signer}

  setup do
    dir = Path.join(System.tmp_dir!(), "trinity-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # `boot!/1` on a temp dir replaces the suite's selection; put the suite's back after.
    on_exit(fn ->
      File.rm_rf!(dir)
      {:ok, _} = KeyCustody.boot!()
    end)

    {:ok, dir: dir}
  end

  describe "the seam" do
    test "each implementation signs and verifies its own family over the PAE, and refuses altered bytes" do
      for impl <- [Signer.Ed25519, Signer.P384], impl.available?() do
        {pub, priv} = impl.generate_key()
        bytes = Envelope.pae(Envelope.receipt_type(impl.scheme()), ~s({"a":1}))
        sig = impl.sign(bytes, priv)
        assert impl.verify(bytes, sig, pub)
        refute impl.verify(bytes <> "x", sig, pub)
        # A signature over the bare body is not a signature over the envelope: the type is
        # inside the signed bytes (research amendment A).
        refute impl.verify(~s({"a":1}), sig, pub)
      end
    end

    test "the scheme strings resolve to their implementation and carry the family" do
      assert {:ok, Signer.Ed25519} = Signer.impl_for_scheme("receipt_v2_ed25519")
      assert {:ok, Signer.P384} = Signer.impl_for_scheme("receipt_v2_p384")
      assert {:ok, Signer.MLDSA87} = Signer.impl_for_scheme("receipt_v2_mldsa87")
      assert :error = Signer.impl_for_scheme("receipt_v1_ed25519")
    end

    test "ML-DSA-87 reports itself unavailable or available from the runtime, never from the build" do
      assert Signer.MLDSA87.available?() == :mldsa87 in :crypto.supports(:public_keys)
    end

    test "the RFC 7638 thumbprint: lexicographic members, no whitespace, SHA-256, base64url" do
      # RFC 7638 section 3.1's example is RSA; the rule is the same and this is the OKP case
      # computed by hand from the definition.
      jwk = %{"kty" => "OKP", "crv" => "Ed25519", "x" => "abc"}
      expected = :crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"abc"}))
      assert Signer.thumbprint(jwk) == Base.url_encode64(expected, padding: false)
    end
  end

  describe "selection" do
    test "outside FIPS mode the default is Ed25519, and in FIPS mode it would be P-384" do
      assert :crypto.info_fips() != :enabled
      assert {:ok, :ed25519} = KeyCustody.select()
    end

    test "a configured ML-DSA-87 is refused where the runtime lacks it, naming the algorithm" do
      Application.put_env(:trinity, :receipts, algorithm: :mldsa87, keys_dir: nil)
      on_exit(fn -> Application.put_env(:trinity, :receipts, keys_dir: test_keys_dir()) end)

      case Signer.MLDSA87.available?() do
        false -> assert {:error, {:no_approved_signer, :mldsa87, _}} = KeyCustody.select()
        true -> assert {:ok, :mldsa87} = KeyCustody.select()
      end
    end
  end

  describe "custody" do
    test "boot generates the key once (0600), appends its registry row, and a second boot reuses it",
         %{dir: dir} do
      assert {:ok, %{algorithm: :ed25519, key_id: key_id, key_path: path}} = KeyCustody.boot!(dir)
      assert File.exists?(path)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert {:ok, [row]} = KeyRegistry.read(dir)
      assert row["key_id"] == key_id
      assert row["algorithm"] == "ed25519"
      assert row["scheme"] == "receipt_v2_ed25519"
      assert row["kid_scheme"] == "rfc7638"
      assert row["status"] == "active"
      assert key_id == Signer.thumbprint(row["jwk"])

      assert {:ok, %{key_id: ^key_id}} = KeyCustody.boot!(dir)
      assert {:ok, [_one]} = KeyRegistry.read(dir)
    end

    test "sign reads the key file at every call: removed mid-run, the next sign is unavailable",
         %{dir: dir} do
      {:ok, %{key_path: path}} = KeyCustody.boot!(dir)
      assert {:ok, sig} = KeyCustody.sign("bytes")
      assert is_binary(sig)
      File.rm!(path)
      assert {:error, :signer_unavailable} = KeyCustody.sign("bytes")
    end

    test "the registry is append-only: a status change is a new row and the newest wins", %{
      dir: dir
    } do
      {:ok, %{key_id: key_id}} = KeyCustody.boot!(dir)
      {:ok, [row]} = KeyRegistry.read(dir)

      compromised =
        Map.merge(row, %{"status" => "compromised", "valid_from" => "2026-09-21T00:00:00Z"})

      assert {:ok, [^row, ^compromised]} = KeyRegistry.append(dir, compromised)
      {:ok, rows} = KeyRegistry.read(dir)
      assert KeyRegistry.lookup(rows, key_id)["status"] == "compromised"
      assert KeyRegistry.active_for(rows, :ed25519) == nil
    end

    test "a key file whose id is not in the registry refuses to boot, naming the id", %{dir: dir} do
      {:ok, %{key_path: path}} = KeyCustody.boot!(dir)
      File.rm!(KeyRegistry.path(dir))
      assert {:error, {:key_not_in_registry, _}} = KeyCustody.boot!(dir)
      assert File.exists?(path)
    end
  end

  defp test_keys_dir, do: Path.expand("../../../tmp/test_keys", __DIR__)
end
