# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Signer.P384 do
  @moduledoc """
  ECDSA on secp384r1 with SHA-384 through `:crypto`; selected when FIPS mode is enabled
  (slice 024, amendment 2). The signature is DER as OTP returns it, 102 to 104 bytes
  (measured at G1; SLICE.md's table says 96, which is the raw r||s size).
  """
  @behaviour Trinity.Receipts.Signer

  @impl true
  def algorithm, do: :p384

  @impl true
  def scheme, do: "receipt_v2_p384"

  @impl true
  def available?, do: :secp384r1 in :crypto.supports(:curves)

  @impl true
  def generate_key, do: :crypto.generate_key(:ecdh, :secp384r1)

  @impl true
  def sign(bytes, priv) when is_binary(bytes) and is_binary(priv),
    do: :crypto.sign(:ecdsa, :sha384, bytes, [priv, :secp384r1])

  @impl true
  def verify(bytes, sig, pub) when is_binary(bytes) and is_binary(sig) and is_binary(pub),
    do: :crypto.verify(:ecdsa, :sha384, bytes, sig, [pub, :secp384r1])

  # The public key is the uncompressed point 0x04 || x || y, 97 bytes.
  @impl true
  def jwk(<<4, x::binary-size(48), y::binary-size(48)>>) do
    %{
      "crv" => "P-384",
      "kty" => "EC",
      "x" => Base.url_encode64(x, padding: false),
      "y" => Base.url_encode64(y, padding: false)
    }
  end

  @impl true
  def encode_private(priv), do: priv

  @impl true
  def decode_private(bin), do: bin
end
