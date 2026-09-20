# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Message do
  @moduledoc """
  One append-only row per message. `seq` is assigned by `Trinity.Sessions.append_message/2`
  inside a transaction and is never taken from the caller; the unique index on
  `(session_id, seq)` is the last line of defence on both adapters.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @roles ~w(system user assistant tool)

  @type t :: %__MODULE__{}

  schema "messages" do
    field :seq, :integer
    field :role, :string
    field :content, :string
    field :parts, :map, default: %{}
    field :tool_call_id, :string
    field :usage, :map
    field :provider_meta, :map, default: %{}
    belongs_to :session, Trinity.Sessions.SessionRow
    timestamps()
  end

  @doc "The closed vocabulary of roles, from docs/05."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc """
  The caller's half of a message: role and content are required, the role is one of four,
  and empty content is refused. `seq` and `session_id` are set by the context, not cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:role, :content, :parts, :tool_call_id, :usage, :provider_meta])
    |> validate_required([:role, :content])
    |> validate_inclusion(:role, @roles)
    |> validate_change(:content, fn :content, content ->
      if String.trim(content) == "", do: [content: "cannot be blank"], else: []
    end)
  end

  @doc """
  The one edit the append-only rule allows: a draft becoming final (or interrupted). Casts the
  content, parts and usage of an existing row; never the role, seq or session.
  """
  @spec finalize_changeset(t(), map()) :: Ecto.Changeset.t()
  def finalize_changeset(message, attrs) do
    message
    |> cast(attrs, [:content, :parts, :usage, :provider_meta])
    |> validate_required([:content])
  end

  @doc false
  @spec place(Ecto.Changeset.t(), String.t(), pos_integer()) :: Ecto.Changeset.t()
  def place(changeset, session_id, seq) do
    changeset
    |> put_change(:session_id, session_id)
    |> put_change(:seq, seq)
    |> unique_constraint([:session_id, :seq], name: :messages_session_id_seq_index)
  end
end
