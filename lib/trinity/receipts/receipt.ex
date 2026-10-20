# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Receipt do
  @moduledoc """
  One row of a receipt chain (slice 024, docs/05). Never updated, never deleted.

  A v2 or v3 row: `signed_payload` is the RFC 8785 body the signature covers through the PAE;
  `receipt_hash` is SHA-256 over those PAE bytes and the next row's `prev_hash`; `signature` is
  present for decision, effect, boot and cap receipts and absent for query receipts, which a
  checkpoint covers.

  A v4 row (slice 140, `Trinity.Receipts.V4`): `body` is its N6 statement body, `receipt_hash` its
  `statement_id` in hex, `prev_hash` the predecessor's link id in hex, `carrier` the single-signer
  carrier for a signed kind (`signature` holds the same signature, though a verifier reads the
  carrier), and `subject_bytes` and `decision_bytes` the exact RFC 8785 bytes its
  ForeignRefs name. `signed_payload` is empty. The `subject` map is kept for the receipts page and
  is never what a verifier reads.
  """
  use Ecto.Schema

  @primary_key {:id, Trinity.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "receipts" do
    field :chain_scope, :string
    field :seq, :integer
    field :prev_hash, :string
    field :receipt_hash, :string
    field :scheme, :string
    field :kind, :string
    field :signed_payload, :string
    field :signature, :binary
    field :key_id, :string
    field :subject, :map, default: %{}
    field :subject_ref, :string
    field :meta, :map, default: %{}
    field :body, :binary
    field :carrier, :binary
    field :subject_bytes, :binary
    field :decision_bytes, :binary
    field :inserted_at, :utc_datetime_usec
  end

  @kinds ~w(decision effect query boot cap)
  @signed_kinds ~w(decision effect boot cap)

  @doc "The five kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The kinds signed one by one; `query` is checkpointed instead."
  @spec signed?(String.t()) :: boolean()
  def signed?(kind), do: kind in @signed_kinds

  @doc "The row as the export and the standalone verifier read it."
  @spec to_export(t()) :: map()
  def to_export(%__MODULE__{} = r) do
    %{
      "chain_scope" => r.chain_scope,
      "seq" => r.seq,
      "prev_hash" => r.prev_hash,
      "receipt_hash" => r.receipt_hash,
      "scheme" => r.scheme,
      "kind" => r.kind,
      "signed_payload" => r.signed_payload,
      "signature_b64" => r.signature && Base.encode64(r.signature),
      "key_id" => r.key_id,
      "meta" => r.meta
    }
    |> put_b64("body_b64", r.body)
    |> put_b64("carrier_b64", r.carrier)
    |> put_b64("subject_b64", r.subject_bytes)
    |> put_b64("decision_b64", r.decision_bytes)
  end

  @doc false
  def put_b64(map, _key, nil), do: map
  def put_b64(map, key, bytes), do: Map.put(map, key, Base.encode64(bytes))
end
