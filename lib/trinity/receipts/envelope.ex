# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Envelope do
  @moduledoc """
  The bytes a signature covers (slice 024, research amendment A). A receipt body is RFC 8785
  canonical JSON; the signature is over DSSE's pre-authentication encoding of a payload type
  and that body, `"DSSEv1" SP LEN(type) SP type SP LEN(body) SP body`, with the type naming
  what the bytes are (`trinity/receipt/<scheme>`, `trinity/checkpoint/<scheme>`). The same key
  signs receipts here and, at slice 061, MCP envelopes; the type inside the signed bytes is
  what keeps a signature made for one from being presented as the other.
  """

  @doc "RFC 8785 canonical JSON of a term with string keys."
  @spec canonical(map()) :: String.t()
  def canonical(map) when is_map(map), do: Jcs.encode(map)

  @doc "DSSE's PAE over a payload type and a body."
  @spec pae(String.t(), binary()) :: binary()
  def pae(type, body) when is_binary(type) and is_binary(body) do
    "DSSEv1 " <>
      Integer.to_string(byte_size(type)) <>
      " " <> type <> " " <> Integer.to_string(byte_size(body)) <> " " <> body
  end

  @doc "The payload type of a receipt of this scheme."
  @spec receipt_type(String.t()) :: String.t()
  def receipt_type(scheme), do: "trinity/receipt/" <> scheme

  @doc "The payload type of a checkpoint of this scheme."
  @spec checkpoint_type(String.t()) :: String.t()
  def checkpoint_type(scheme), do: "trinity/checkpoint/" <> scheme

  @doc "SHA-256 of bytes, lowercase hex: the `receipt_hash`, and the next row's `prev_hash`."
  @spec hash(binary()) :: String.t()
  def hash(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
