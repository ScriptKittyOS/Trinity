# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Checkpoint do
  @moduledoc """
  A signed coverage block over a scope's query receipts (slice 024, amendment 5; RFC 5848's
  shape, research amendment D): which boot it belongs to, the first and last seq it covers,
  the tail hash at `last_seq`, and a signature over the PAE of its own canonical body. A
  row, never a write onto a receipt.
  """
  use Ecto.Schema

  @primary_key {:id, Trinity.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "receipt_checkpoints" do
    field :chain_scope, :string
    field :boot_receipt_hash, :string
    field :first_seq, :integer
    field :last_seq, :integer
    field :tail_hash, :string
    field :scheme, :string
    field :signed_payload, :string
    field :signature, :binary
    field :key_id, :string
    field :reason, :string
    field :inserted_at, :utc_datetime_usec
  end

  @doc "The row as the export and the standalone verifier read it."
  @spec to_export(t()) :: map()
  def to_export(%__MODULE__{} = c) do
    %{
      "chain_scope" => c.chain_scope,
      "boot_receipt_hash" => c.boot_receipt_hash,
      "first_seq" => c.first_seq,
      "last_seq" => c.last_seq,
      "tail_hash" => c.tail_hash,
      "scheme" => c.scheme,
      "signed_payload" => c.signed_payload,
      "signature_b64" => Base.encode64(c.signature),
      "key_id" => c.key_id,
      "reason" => c.reason
    }
  end
end
