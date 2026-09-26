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

  @doc """
  The scheme string a receipt of this family carries, at the current version:
  `receipt_<version>_<family>`.

  Slice 026 moved the current version from `v2` to `v3`, because `v3` carries a hybrid logical
  clock in the signed payload and `v2` does not. Both are accepted on read (`accepted_schemes/0`):
  a chain that spans the bump verifies row by row under each row's own scheme, which is what makes
  this a scheme bump rather than an edit to bytes already signed.
  """
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

  # Every scheme version this tree can read, oldest first. `v2` is slice 024's; `v3` is slice 026's
  # and carries the clock. A version is removed from here only when no chain in the world still has
  # a row of it, which is not a thing this project can know, so in practice it is never removed.
  @scheme_versions ["v2", "v3"]

  # The version new rows are written under.
  @current_scheme_version "v3"

  @doc "The scheme versions this tree can verify, oldest first."
  @spec scheme_versions() :: [String.t()]
  def scheme_versions, do: @scheme_versions

  @doc "The scheme version new rows are written under."
  @spec current_scheme_version() :: String.t()
  def current_scheme_version, do: @current_scheme_version

  @doc """
  Every scheme this tree accepts on read: each algorithm at each readable version.

  This is the verifier's default allow-list rather than the current schemes alone. Defaulting to
  the current schemes would mean that bumping the version made every previously signed row fail to
  verify, which is the opposite of what a bump is for.
  """
  @spec accepted_schemes() :: [String.t()]
  def accepted_schemes do
    for v <- @scheme_versions, a <- algorithms(), do: "receipt_#{v}_#{a}"
  end

  @doc """
  Splits a scheme string into its version and family, or `:error`.

  The shape is `receipt_<version>_<family>`; no family contains an underscore, which is why
  splitting into two parts is safe and is asserted by a test rather than assumed.
  """
  @spec parse_scheme(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_scheme("receipt_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [version, family] when version in @scheme_versions -> {:ok, version, family}
      _ -> :error
    end
  end

  def parse_scheme(_), do: :error

  @doc """
  True when a scheme's signed payload carries a hybrid logical clock.

  `v2` predates slice 026 and has no clock; asking a `v2` row for one is a question about a row
  that was signed before the field existed, and the verifier must not treat its absence as a fault.
  """
  @spec clocked?(String.t()) :: boolean()
  def clocked?(scheme) do
    case parse_scheme(scheme) do
      {:ok, version, _family} -> version >= "v3"
      :error -> false
    end
  end

  @doc "The implementation whose scheme string this is, at any readable version, or `:error`."
  @spec impl_for_scheme(String.t()) :: {:ok, module()} | :error
  def impl_for_scheme(scheme) do
    with {:ok, _version, family} <- parse_scheme(scheme),
         {:ok, algorithm} <- family_to_algorithm(family) do
      {:ok, Map.fetch!(@implementations, algorithm)}
    else
      _ -> :error
    end
  end

  defp family_to_algorithm(family) do
    case Enum.find(algorithms(), &(Atom.to_string(&1) == family)) do
      nil -> :error
      algorithm -> {:ok, algorithm}
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
