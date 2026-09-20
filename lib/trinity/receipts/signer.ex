# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Signer do
  @moduledoc """
  The signer seam (slice 024, amendment 1): one behaviour, one algorithm per implementation,
  selected once at boot by `Trinity.Receipts.KeyCustody`. A receipt names its family in its
  scheme string and its key in `key_id`; the verifier takes the algorithm from the key
  registry row and never from the receipt (amendment 3, RFC 8725 section 3.1).

  Implementations: `Ed25519` (the default), `P384` (selected when `crypto:info_fips/0` is
  `enabled`), `MLDSA87` (opt-in, available only where the linked OpenSSL carries it).
  """

  @type algorithm :: :ed25519 | :p384 | :mldsa87
  @type public_key :: binary()
  @type private_key :: term()

  @doc "The algorithm this implementation signs with."
  @callback algorithm() :: algorithm()

  @doc "The scheme string a receipt of this family carries: `receipt_v2_<family>`."
  @callback scheme() :: String.t()

  @doc "True where this runtime can sign and verify with this algorithm."
  @callback available?() :: boolean()

  @doc "A fresh key pair."
  @callback generate_key() :: {public_key(), private_key()}

  @doc "Signs `bytes` with the private key; the bytes are the PAE, never a bare payload."
  @callback sign(bytes :: binary(), private_key()) :: binary()

  @doc "Verifies `signature` over `bytes` with the public key."
  @callback verify(bytes :: binary(), signature :: binary(), public_key()) :: boolean()

  @doc """
  The RFC 7638 required JWK members for the public key (`crv`, `kty`, `x`, `y` for EC; `crv`,
  `kty`, `x` for OKP), or `nil` where no JWK form is registered for the algorithm.
  """
  @callback jwk(public_key()) :: map() | nil

  @doc "Encodes a private key for the key file; the inverse of `decode_private/1`."
  @callback encode_private(private_key()) :: binary()

  @doc "Decodes a private key from the key file."
  @callback decode_private(binary()) :: private_key()

  @implementations %{
    ed25519: Trinity.Receipts.Signer.Ed25519,
    p384: Trinity.Receipts.Signer.P384,
    mldsa87: Trinity.Receipts.Signer.MLDSA87
  }

  @doc "The implementation for an algorithm."
  @spec impl(algorithm()) :: module()
  def impl(algorithm) when is_map_key(@implementations, algorithm),
    do: Map.fetch!(@implementations, algorithm)

  @doc "The implementation whose scheme string this is, or `:error`."
  @spec impl_for_scheme(String.t()) :: {:ok, module()} | :error
  def impl_for_scheme(scheme) do
    case Enum.find(@implementations, fn {_, m} -> m.scheme() == scheme end) do
      {_, m} -> {:ok, m}
      nil -> :error
    end
  end

  @doc "Every algorithm this tree knows, in the order of preference outside FIPS mode."
  @spec algorithms() :: [algorithm()]
  def algorithms, do: [:ed25519, :p384, :mldsa87]

  @doc """
  The RFC 7638 thumbprint of a JWK: the required members serialised with no whitespace in
  lexicographic order, SHA-256, base64url without padding.
  """
  @spec thumbprint(map()) :: String.t()
  def thumbprint(jwk) when is_map(jwk) do
    json =
      jwk
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",", fn {k, v} -> ~s("#{k}":"#{v}") end)

    :crypto.hash(:sha256, "{" <> json <> "}") |> Base.url_encode64(padding: false)
  end
end
