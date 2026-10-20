# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Digest do
  @moduledoc """
  Digests of foreign bytes inside N6 bodies (the profile's section 4; slice 138).

  Bytes someone else produced are never parsed, normalised or re-encoded before they are hashed.
  They are referenced by a digest over exactly the bytes as received:

    * `Digest = [hashAlg, hashValue]`, the shape of RFC 9054's `COSE_Hash_Find` example, with
      `hashAlg` -43 (SHA-384, RFC 9054) and a 48-byte value;
    * `ForeignRef = {0: Digest, 1: length, 2: media type, ? 3: locator}`, the length being the
      exact number of bytes received.

  SHA-384 is the only algorithm accepted. The profile leaves SHA-512 (-44) Open for v0; until it
  is decided this tree refuses it with the rest (`digest_alg_not_permitted`). A value whose length
  does not match its algorithm is `digest_length_mismatch`, and anything that is not a two-element
  array of an integer and a byte string is `digest_malformed`; both are this tree's codes until
  the profile names its own.
  """

  alias Trinity.N6.{CBOR, Profile}

  @sha384 -43

  @doc "The Digest of bytes exactly as given."
  @spec of(binary()) :: [integer() | {:bytes, binary()}]
  def of(bytes) when is_binary(bytes), do: [@sha384, {:bytes, :crypto.hash(:sha384, bytes)}]

  @doc "A ForeignRef to bytes exactly as given, with their media type and an optional locator."
  @spec foreign_ref(binary(), String.t(), String.t() | nil) :: %{
          non_neg_integer() => CBOR.value()
        }
  def foreign_ref(bytes, media_type, locator \\ nil)
      when is_binary(bytes) and is_binary(media_type) do
    ref = %{0 => of(bytes), 1 => byte_size(bytes), 2 => {:text, media_type}}
    if locator, do: Map.put(ref, 3, {:text, locator}), else: ref
  end

  @doc "Whether a decoded value is a Digest this profile accepts."
  @spec check(CBOR.value()) :: :ok | {:error, Profile.code()}
  def check([@sha384, {:bytes, value}]) when byte_size(value) == 48, do: :ok
  def check([@sha384, {:bytes, _value}]), do: {:error, :digest_length_mismatch}
  def check([alg, {:bytes, _value}]) when is_integer(alg), do: {:error, :digest_alg_not_permitted}
  def check(_other), do: {:error, :digest_malformed}

  @doc "Whether a Digest this profile accepts is the digest of these bytes."
  @spec matches?(CBOR.value(), binary()) :: boolean()
  def matches?(digest, bytes) when is_binary(bytes),
    do: check(digest) == :ok and digest == of(bytes)
end
