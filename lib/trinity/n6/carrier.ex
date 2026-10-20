# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Carrier do
  @moduledoc """
  The single-signer carrier (slice 139): how one N6 statement with one signature travels.

      {0: SINGLE_SCHEMA, 1: payload, 2: [protected, {}, nil, signature]}

  The profile publisher's answer of 2026-10-19 (item 3), ahead of the draft that will carry it: key
  0 is a schema number in the reserved carrier range, key 1 the payload as a byte string (the N6
  statement body), key 2 the Sign1, untagged and with its payload field nil (detached), as the twin
  envelope holds each of its two. ToBeSigned is over key 1's bytes (`Trinity.N6.COSE`). The tagged,
  attached Sign1 is a rendering only (`COSE.render/2`), never this carrier.

  `SINGLE_SCHEMA` is a placeholder, 0xFFFF0003, until the profile assigns it
  (`Trinity.N6.Profile.schemas/0`).

  ## Refusals

  The carrier is decoded whole by the codec first, so an encoding defect anywhere in it, a tagged
  Sign1 among them (`tag_forbidden`, E6), is the codec's code. Then the shape: anything but a map of
  exactly keys 0, 1 and 2, with key 0 the single-signer schema, key 1 a byte string and key 2 a
  four-element Sign1 with a nil payload, is `carrier_malformed`. The unprotected header follows the
  rules `COSE.parse/3` applies.

  `verify/2` also refuses a `typ` whose table entry is not `carrier: single, signers: single`
  (`wrong_carrier_for_typ`), before any signature is looked at: each of a twin's two signatures is a
  valid single signature on its own, so a single-signer entry point that accepted one would accept
  half a twin as a whole statement.
  """

  alias Trinity.N6.{CBOR, COSE, Profile}

  @doc "The carrier bytes for a Sign1's parts."
  @spec encode(COSE.parts()) :: binary()
  def encode(%{protected: p, payload: payload, signature: s})
      when is_binary(p) and is_binary(payload) and is_binary(s) do
    CBOR.encode!(%{
      0 => Profile.schema(:single),
      1 => {:bytes, payload},
      2 => [{:bytes, p}, %{}, nil, {:bytes, s}]
    })
  end

  @doc "A carrier's Sign1 parts, strictly decoded, or the code of its first defect."
  @spec decode(binary()) :: {:ok, COSE.parts()} | {:error, Profile.code()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, value} <- codec(bytes),
         {:ok, payload, sign1} <- shape(value),
         {:ok, p, s} <- sign1(sign1) do
      {:ok, %{protected: p, payload: payload, signature: s}}
    end
  end

  @doc """
  Verifies a carrier. `opts` as `COSE.verify/2` takes them (`keys`, `typ`, `entry`). The `typ`'s
  table entry must say `carrier: single` and `signers: single`.
  """
  @spec verify(binary(), keyword()) ::
          {:ok, %{exit: 0, verdict_code: :claim, kid: binary(), typ: String.t()}}
          | {:error, 1 | 5, Profile.code()}
  def verify(bytes, opts) when is_binary(bytes) do
    table = Keyword.fetch!(opts, :typ)
    entry_point = Keyword.get(opts, :entry, :nss)

    with {:ok, parts} <- decode(bytes),
         {:ok, %{entry: entry}} <- COSE.decode_protected(parts.protected, table, entry_point),
         :ok <- single(entry) do
      COSE.verify(parts, opts)
    else
      {:error, code} -> {:error, Profile.exit_of(code), code}
    end
  end

  defp codec(bytes) do
    case CBOR.decode(bytes) do
      {:ok, value} -> {:ok, value}
      {:error, code, _offset} -> {:error, code}
    end
  end

  defp shape(%{0 => schema, 1 => {:bytes, payload}, 2 => sign1} = map)
       when map_size(map) == 3 do
    if schema == Profile.schema(:single),
      do: {:ok, payload, sign1},
      else: {:error, :carrier_malformed}
  end

  defp shape(_other), do: {:error, :carrier_malformed}

  defp sign1([{:bytes, p}, unprotected, nil, {:bytes, s}]) do
    with :ok <- COSE.unprotected(unprotected), do: {:ok, p, s}
  end

  defp sign1(_other), do: {:error, :carrier_malformed}

  defp single(%{carrier: :single, signers: :single}), do: :ok
  defp single(_entry), do: {:error, :wrong_carrier_for_typ}
end
