# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.SessionRow do
  @moduledoc """
  A conversation's row. Slice 010 owns it; slice 012 owns `Trinity.Sessions.Session`, the process
  that runs it, which is why this module carries the `Row` suffix (renamed at slice 012 when the
  process took the name docs/01 gives it). `origin` and `status` are strings with a closed
  vocabulary from docs/05, validated here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @origins ~w(desktop telegram discord console cron subagent mcp a2a)
  @statuses ~w(active archived compacted)

  @type t :: %__MODULE__{}

  schema "sessions" do
    field :title, :string
    field :origin, :string, default: "desktop"
    field :origin_ref, :map, default: %{}
    field :status, :string, default: "active"
    field :model, :string
    field :token_usage, :map, default: %{}
    field :last_activity_at, :utc_datetime_usec
    belongs_to :persona, Trinity.Sessions.Persona
    belongs_to :parent, __MODULE__
    has_many :messages, Trinity.Sessions.Message, foreign_key: :session_id
    timestamps()
  end

  @doc "The closed vocabulary of origins, from docs/05."
  @spec origins() :: [String.t()]
  def origins, do: @origins

  @doc "The closed vocabulary of statuses, from docs/05."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :title,
      :persona_id,
      :parent_id,
      :origin,
      :origin_ref,
      :status,
      :model,
      :token_usage
    ])
    |> validate_required([:persona_id, :origin, :status])
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:persona_id)
    |> foreign_key_constraint(:parent_id)
  end
end
