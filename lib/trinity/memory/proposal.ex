# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Proposal do
  @moduledoc """
  One row of `memory_proposals` (slice 030): a consolidation the model proposed. `entries` is
  the proposed set (`%{"entries" => [%{"tier", "scope", "key", "body"}]}`); applied at once when
  its bytes are under the budget, else `pending` for the owner to apply or reject.
  """
  use Ecto.Schema

  @primary_key {:id, Trinity.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "memory_proposals" do
    field :persona_id, Trinity.UUID
    field :entries, :map, default: %{}
    field :bytes_before, :integer
    field :bytes_after, :integer
    field :budget, :integer
    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
