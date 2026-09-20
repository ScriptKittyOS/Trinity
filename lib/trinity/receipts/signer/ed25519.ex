# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Signer.Ed25519 do
  @moduledoc "Ed25519 (RFC 8032) through `:crypto`; the default outside FIPS mode. Slice 024."
  @behaviour Trinity.Receipts.Signer

  @impl true
  def algorithm, do: :ed25519

  @impl true
  def scheme, do: "receipt_v2_ed25519"

  @impl true
  def available?, do: :ed25519 in :crypto.supports(:curves) and :crypto.info_fips() != :enabled

  @impl true
  def generate_key, do: :crypto.generate_key(:eddsa, :ed25519)

  @impl true
  def sign(bytes, priv) when is_binary(bytes) and is_binary(priv),
    do: :crypto.sign(:eddsa, :none, bytes, [priv, :ed25519])

  @impl true
  def verify(bytes, sig, pub) when is_binary(bytes) and is_binary(sig) and is_binary(pub),
    do: :crypto.verify(:eddsa, :none, bytes, sig, [pub, :ed25519])

  @impl true
  def jwk(pub) when byte_size(pub) == 32,
    do: %{"crv" => "Ed25519", "kty" => "OKP", "x" => Base.url_encode64(pub, padding: false)}

  @impl true
  def encode_private(priv), do: priv

  @impl true
  def decode_private(bin), do: bin
end
