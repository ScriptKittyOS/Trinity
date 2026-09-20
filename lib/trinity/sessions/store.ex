# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Store do
  @moduledoc """
  Every query the Sessions context runs. Internal to `Trinity.Sessions`: the boundary exports
  the context and not this module, so `TrinityWeb` cannot reach the tables except through the
  context's API (slice 010 AC5).
  """
  import Ecto.Query

  alias Trinity.Repo
  alias Trinity.Sessions.{Message, Persona, Session}

  @spec insert_persona(map()) :: {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def insert_persona(attrs), do: %Persona{} |> Persona.changeset(attrs) |> Repo.insert()

  @spec get_persona_by_name(String.t()) :: Persona.t() | nil
  def get_persona_by_name(name), do: Repo.get_by(Persona, name: name)

  @spec insert_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def insert_session(attrs), do: %Session{} |> Session.changeset(attrs) |> Repo.insert()

  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(id), do: Repo.get(Session, id)

  @spec list_sessions(keyword()) :: [Session.t()]
  def list_sessions(opts) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    Session
    |> maybe_status(status)
    |> order_by([s], desc: s.last_activity_at, desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_status(query, nil), do: query
  defp maybe_status(query, status), do: where(query, [s], s.status == ^status)

  @spec update_session(Session.t(), map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(session, attrs), do: session |> Session.changeset(attrs) |> Repo.update()

  @doc """
  Appends one message with the next `seq` for its session, in one transaction. On Postgres the
  session row is locked `FOR UPDATE` so two transactions cannot read the same `max(seq)`; on
  SQLite the single connection serialises the whole transaction, and the unique index on
  `(session_id, seq)` refuses a duplicate on either.
  """
  @spec append_message(String.t(), Ecto.Changeset.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t() | :no_session}
  def append_message(session_id, changeset) do
    Repo.transaction(fn ->
      with %Session{} = session <- lock_session(session_id),
           next = next_seq(session_id),
           {:ok, message} <- changeset |> Message.place(session_id, next) |> Repo.insert(),
           {:ok, _} <- touch(session) do
        message
      else
        nil -> Repo.rollback(:no_session)
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
      end
    end)
  end

  # The adapter is a compile-time fact (config/config.exs), so the row lock is compiled in or
  # out rather than branched at runtime: a Postgres build locks the session row FOR UPDATE; a
  # SQLite build has one connection and needs no row lock. The type checker refuses a
  # runtime branch on a constant, which is how this shape was arrived at. Each build carries
  # exactly one of the two definitions, and the CI matrix compiles both.
  if Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3) ==
       Ecto.Adapters.Postgres do
    defp lock_session(session_id) do
      Repo.one(from(s in Session, where: s.id == ^session_id, lock: "FOR UPDATE"))
    end
  else
    defp lock_session(session_id) do
      Repo.one(from(s in Session, where: s.id == ^session_id))
    end
  end

  defp next_seq(session_id) do
    (Repo.one(from(m in Message, where: m.session_id == ^session_id, select: max(m.seq))) || 0) +
      1
  end

  defp touch(session) do
    session
    |> Ecto.Changeset.change(last_activity_at: DateTime.utc_now())
    |> Repo.update()
  end

  @spec history(String.t(), keyword()) :: [Message.t()]
  def history(session_id, opts) do
    limit = Keyword.get(opts, :limit, 200)
    offset = Keyword.get(opts, :offset, 0)

    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.seq)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @spec message_count(String.t()) :: non_neg_integer()
  def message_count(session_id) do
    Repo.one(from(m in Message, where: m.session_id == ^session_id, select: count(m.id)))
  end

  @spec seqs(String.t()) :: [pos_integer()]
  def seqs(session_id) do
    Repo.all(
      from(m in Message, where: m.session_id == ^session_id, order_by: m.seq, select: m.seq)
    )
  end
end
