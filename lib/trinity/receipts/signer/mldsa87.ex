# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Signer.MLDSA87 do
  @moduledoc """
  ML-DSA-87 (FIPS 204) through `:crypto`, opt-in and never the default (slice 024, amendment
  6). Available only where the linked OpenSSL is 3.5 or later; `available?/0` asks the runtime
  rather than the build, by generating, signing and verifying (`Trinity.Crypto.Preflight`, slice
  137), so the module compiles everywhere and refuses where it cannot run.
  Measured on the slice 003 image (OpenSSL 3.5.8, mode off): a 4,627-byte signature, 905 µs
  to sign, 172 µs to verify; refused in FIPS mode there. The private key OTP returns is a
  tagged tuple (`{:seed | :expandedkey, binary}`), and OTP 28.5.0.8 returns it bare (slice 137,
  F-137-2); the key file keeps the tag either way.

  No JWK form is registered for ML-DSA at this date; `jwk/1` is `nil` and the key id is the
  SHA-256 of the raw public key (`kid_scheme` `sha256-raw` in the registry row).
  """
  @behaviour Trinity.Receipts.Signer

  @impl true
  def algorithm, do: :mldsa87

  @impl true
  def scheme, do: "receipt_v4_mldsa87"

  # Slice 137, F-137-1. This was `:mldsa87 in :crypto.supports(:public_keys)`, which never holds in
  # FIPS mode: OTP lists no ML-DSA type there whatever the provider can do (`pkey.c`,
  # `build_pkey_type_list/3`). The known-answer check asks the provider by doing the operation.
  @impl true
  def available?, do: Trinity.Crypto.Preflight.ok?()

  @impl true
  def generate_key, do: :crypto.generate_key(:mldsa87, [])

  @impl true
  def sign(bytes, priv) when is_binary(bytes), do: :crypto.sign(:mldsa87, :none, bytes, priv)

  @impl true
  def verify(bytes, sig, pub) when is_binary(bytes) and is_binary(sig) and is_binary(pub),
    do: :crypto.verify(:mldsa87, :none, bytes, sig, pub)

  @impl true
  def jwk(_pub), do: nil

  # Slice 137, F-137-2: OTP 28.5.0.8 on OpenSSL 3.5.9 returns the private key bare, as the
  # 4,896-byte expanded key, where the runtime measured at slice 024 returned it tagged. A bare key
  # is stored tagged by its size, so the key file's format is the same whichever runtime made it,
  # and `{:expandedkey, key}` signs on both (measured on 28.5.0.8).
  @expanded_key_bytes 4896
  @seed_bytes 32

  @impl true
  def encode_private({tag, bin}) when tag in [:seed, :expandedkey] and is_binary(bin),
    do: Atom.to_string(tag) <> ":" <> bin

  def encode_private(bin) when is_binary(bin) and byte_size(bin) == @expanded_key_bytes,
    do: "expandedkey:" <> bin

  def encode_private(bin) when is_binary(bin) and byte_size(bin) == @seed_bytes,
    do: "seed:" <> bin

  @impl true
  def decode_private("seed:" <> bin), do: {:seed, bin}
  def decode_private("expandedkey:" <> bin), do: {:expandedkey, bin}
end
