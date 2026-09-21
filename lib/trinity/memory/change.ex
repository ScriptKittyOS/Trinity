# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Change do
  @moduledoc "One row of `memory_changes` (slice 030): every write to the always-on tiers, by whom, with the body before and after."
  use Ecto.Schema

  @primary_key {:id, Trinity.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "memory_changes" do
    field :persona_id, Trinity.UUID
    field :action, :string
    field :tier, :string
    field :scope, :string
    field :key, :string
    field :before, :string
    field :after, :string
    field :by, :string
    field :session_id, Trinity.UUID
    field :proposal_id, Trinity.UUID
    field :inserted_at, :utc_datetime_usec
  end
end
