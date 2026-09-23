# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Identity do
  @moduledoc """
  One row of `gateway_identities` (slice 070, docs/05, docs/07 "Gateways"): a person on one
  outside platform and what Trinity will do for them. The key is the pair `(adapter,
  external_user_id)`, because an id means nothing outside the platform that issued it.

  `state` is `pending` (a pairing code has been shown and not yet entered), `paired` (the owner
  typed the code into the desktop's channel, which is the proof) or `revoked`. A revoked row is
  kept rather than deleted: an id that was turned away should be visible on the page, not absent
  from it, and pairing again is then a deliberate act with a record.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @states ~w(pending paired revoked)

  schema "gateway_identities" do
    field :adapter, :string
    field :external_user_id, :string
    field :display_name, :string
    field :state, :string, default: "pending"
    field :code, :string
    field :code_expires_at, :utc_datetime_usec
    field :paired_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_conversation, :string
    timestamps()
  end

  @doc "The states a row may be in."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "A changeset for an identity."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :adapter,
      :external_user_id,
      :display_name,
      :state,
      :code,
      :code_expires_at,
      :paired_at,
      :revoked_at,
      :last_conversation
    ])
    |> validate_required([:adapter, :external_user_id, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:adapter, :external_user_id])
  end

  @doc "True when this identity may talk to Trinity right now."
  @spec paired?(t()) :: boolean()
  def paired?(%__MODULE__{state: "paired"}), do: true
  def paired?(%__MODULE__{}), do: false
end
