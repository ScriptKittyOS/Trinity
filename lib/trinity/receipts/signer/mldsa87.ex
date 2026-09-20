# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Signer.MLDSA87 do
  @moduledoc """
  ML-DSA-87 (FIPS 204) through `:crypto`, opt-in and never the default (slice 024, amendment
  6). Available only where the linked OpenSSL is 3.5 or later; `available?/0` asks the runtime
  rather than the build, so the module compiles everywhere and refuses where it cannot run.
  Measured on the slice 003 image (OpenSSL 3.5.8, mode off): a 4,627-byte signature, 905 µs
  to sign, 172 µs to verify; refused in FIPS mode there. The private key OTP returns is a
  tagged tuple (`{:seed | :expandedkey, binary}`); the key file keeps the tag.

  No JWK form is registered for ML-DSA at this date; `jwk/1` is `nil` and the key id is the
  SHA-256 of the raw public key (`kid_scheme` `sha256-raw` in the registry row).
  """
  @behaviour Trinity.Receipts.Signer

  @impl true
  def algorithm, do: :mldsa87

  @impl true
  def scheme, do: "receipt_v2_mldsa87"

  @impl true
  def available?, do: :mldsa87 in :crypto.supports(:public_keys)

  @impl true
  def generate_key, do: :crypto.generate_key(:mldsa87, [])

  @impl true
  def sign(bytes, priv) when is_binary(bytes), do: :crypto.sign(:mldsa87, :none, bytes, priv)

  @impl true
  def verify(bytes, sig, pub) when is_binary(bytes) and is_binary(sig) and is_binary(pub),
    do: :crypto.verify(:mldsa87, :none, bytes, sig, pub)

  @impl true
  def jwk(_pub), do: nil

  @impl true
  def encode_private({tag, bin}) when tag in [:seed, :expandedkey] and is_binary(bin),
    do: Atom.to_string(tag) <> ":" <> bin

  @impl true
  def decode_private("seed:" <> bin), do: {:seed, bin}
  def decode_private("expandedkey:" <> bin), do: {:expandedkey, bin}
end
