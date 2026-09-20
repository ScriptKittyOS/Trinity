# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions do
  @moduledoc """
  The persistence API for sessions and messages. Slice 010.

  The only public surface over the `personas`, `sessions` and `messages` tables. `boundary`
  exports this module alone; `Trinity.Sessions.Store` and the schemas stay inside. Slice 012
  adds the session process on top of this API and changes nothing here.
  """
  # Slice 012: Sessions reaches the LLM (docs/01: Sessions depends on LLM, Repo, PubSub).
  # Slice 020: and the tool runtime, for the declared surface and the runner in force.
  # Slice 023: and Memory, for the estimate and the compaction before a model call.
  use Boundary,
    deps: [Trinity, Trinity.LLM, Trinity.Tools, Trinity.Memory],
    exports: [Events, Message, Persona, SessionRow, Session, Caps, Prompt]

  alias Trinity.Sessions.{Message, Persona, SessionRow, Store}

  @type session_id :: String.t()

  @doc "Creates a persona. `name` is required and unique."
  @spec create_persona(map()) :: {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def create_persona(attrs), do: Store.insert_persona(attrs)

  @doc "The persona with this name, or nil."
  @spec get_persona_by_name(String.t()) :: Persona.t() | nil
  def get_persona_by_name(name), do: Store.get_persona_by_name(name)

  @doc "Creates a session. `persona_id` is required; `origin` and `status` come from a closed vocabulary."
  @spec create_session(map()) :: {:ok, SessionRow.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs), do: Store.insert_session(attrs)

  @doc "The session with this id, or nil."
  @spec get_session(session_id()) :: SessionRow.t() | nil
  def get_session(id), do: Store.get_session(id)

  @doc "Sessions, most recently active first. Options: `status:`, `limit:` (default 50)."
  @spec list_sessions(keyword()) :: [SessionRow.t()]
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
  @spec archive(SessionRow.t()) :: {:ok, SessionRow.t()} | {:error, Ecto.Changeset.t()}
  def archive(%SessionRow{} = session), do: Store.update_session(session, %{status: "archived"})

  @default_persona_name "default"

  @doc """
  The persona new sessions belong to: the row named `default`, created on first use with no
  soul (so the prompt keeps its fallback). Slice 013 adds it so the chat can open a session;
  slice 030 seeds the SOUL into this same row.
  """
  @spec default_persona() :: Persona.t()
  def default_persona do
    case Store.get_persona_by_name(@default_persona_name) do
      nil ->
        case Store.insert_persona(%{name: @default_persona_name}) do
          {:ok, persona} -> persona
          # Two callers raced; the unique index let one through, and it is the row.
          {:error, _} -> Store.get_persona_by_name(@default_persona_name)
        end

      persona ->
        persona
    end
  end

  @doc "Sets the session's title (the chat uses the first message's opening line)."
  @spec set_title(session_id(), String.t()) :: {:ok, SessionRow.t()} | {:error, term()}
  def set_title(session_id, title) do
    case Store.get_session(session_id) do
      nil -> {:error, :no_session}
      session -> Store.update_session(session, %{title: title})
    end
  end

  @doc """
  Sets the session's model to a registry id, or to nil for the registry default; refuses an id
  the registry does not know. The running process reads the row at the start of each turn, so
  the next turn uses it (slice 013, AC6).
  """
  @spec set_model(session_id(), String.t() | nil) :: {:ok, SessionRow.t()} | {:error, term()}
  def set_model(session_id, model) do
    with {:ok, _entry} <- Trinity.LLM.Registry.lookup(model),
         %SessionRow{} = session <- Store.get_session(session_id) || {:error, :no_session} do
      Store.update_session(session, %{model: model})
    end
  end

  @doc "The number of messages in a session."
  @spec message_count(session_id()) :: non_neg_integer()
  def message_count(session_id), do: Store.message_count(session_id)

  @doc "Every `seq` in a session, ascending. The stress test's population."
  @spec seqs(session_id()) :: [pos_integer()]
  def seqs(session_id), do: Store.seqs(session_id)

  ## The process (slice 012)

  alias Trinity.Sessions.{Events, Session, Supervisor}

  @doc "Starts the session's process, or returns the running one. The row must exist."
  @spec start_session(session_id()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id), do: Supervisor.start_session(session_id)

  @doc "Idempotent: the running pid, or a fresh process rehydrated from the database."
  @spec ensure_started(session_id()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id) do
    case whereis(session_id) do
      nil -> start_session(session_id)
      pid -> {:ok, pid}
    end
  end

  @doc "The session's pid, if its process is running."
  @spec whereis(session_id()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(Trinity.Registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Persists the user's message and starts a turn; refuses while a turn is in flight."
  @spec send_user_message(session_id(), String.t()) :: {:ok, Message.t()} | {:error, term()}
  def send_user_message(session_id, content) do
    with {:ok, pid} <- ensure_started(session_id), do: Session.send_user_message(pid, content)
  end

  @doc "Stops the turn in flight, persisting what arrived as interrupted."
  @spec cancel_turn(session_id()) :: :ok | {:error, term()}
  def cancel_turn(session_id) do
    case whereis(session_id) do
      nil -> {:error, :not_running}
      pid -> Session.cancel_turn(pid)
    end
  end

  @doc "The state name and a redacted view of the process's data."
  @spec state(session_id()) :: map() | {:error, :not_running}
  def state(session_id) do
    case whereis(session_id) do
      nil -> {:error, :not_running}
      pid -> Session.state(pid)
    end
  end

  @doc "Subscribes the caller to the session's events on `session:<id>`."
  @spec subscribe(session_id()) :: :ok | {:error, term()}
  def subscribe(session_id), do: Events.subscribe(session_id)
end
