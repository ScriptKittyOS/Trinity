# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions do
  @moduledoc """
  The persistence API for sessions and messages. Slice 010.

  The only public surface over the `personas`, `sessions` and `messages` tables. `boundary`
  exports this module alone; `Trinity.Sessions.Store` and the schemas stay inside. Slice 012
  adds the session process on top of this API and changes nothing here.
  """
  use Boundary, deps: [Trinity], exports: []

  alias Trinity.Sessions.{Message, Persona, Session, Store}

  @type session_id :: String.t()

  @doc "Creates a persona. `name` is required and unique."
  @spec create_persona(map()) :: {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def create_persona(attrs), do: Store.insert_persona(attrs)

  @doc "The persona with this name, or nil."
  @spec get_persona_by_name(String.t()) :: Persona.t() | nil
  def get_persona_by_name(name), do: Store.get_persona_by_name(name)

  @doc "Creates a session. `persona_id` is required; `origin` and `status` come from a closed vocabulary."
  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs), do: Store.insert_session(attrs)

  @doc "The session with this id, or nil."
  @spec get_session(session_id()) :: Session.t() | nil
  def get_session(id), do: Store.get_session(id)

  @doc "Sessions, most recently active first. Options: `status:`, `limit:` (default 50)."
  @spec list_sessions(keyword()) :: [Session.t()]
  def list_sessions(opts \\ []), do: Store.list_sessions(opts)

  @doc """
  Appends a message to a session, assigning the next gapless `seq` atomically. Rejects an
  unknown role or empty content with `{:error, %Ecto.Changeset{}}` and a missing session with
  `{:error, :no_session}`. Touches the session's `last_activity_at`.
  """
  @spec append_message(session_id(), map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t() | :no_session}
  def append_message(session_id, attrs) do
    changeset = Message.changeset(%Message{}, attrs)

    if changeset.valid? do
      Store.append_message(session_id, changeset)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc "Messages in `seq` order. Options: `limit:` (default 200), `offset:` (default 0)."
  @spec history(session_id(), keyword()) :: [Message.t()]
  def history(session_id, opts \\ []), do: Store.history(session_id, opts)

  @doc "Marks a session archived."
  @spec archive(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Session{} = session), do: Store.update_session(session, %{status: "archived"})

  @doc "The number of messages in a session."
  @spec message_count(session_id()) :: non_neg_integer()
  def message_count(session_id), do: Store.message_count(session_id)

  @doc "Every `seq` in a session, ascending. The stress test's population."
  @spec seqs(session_id()) :: [pos_integer()]
  def seqs(session_id), do: Store.seqs(session_id)
end
