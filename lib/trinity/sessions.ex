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
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  use Boundary,
    # Slice 030: Receipts, for the prompt truncation receipt (docs/01's row as built).
    deps: [Trinity, Trinity.LLM, Trinity.Tools, Trinity.Memory, Trinity.Receipts],
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

  @doc """
  The most recent `limit` rows, ascending: the window a prompt is built from (slice 014).

  Not `history/2`, which pages forwards from the beginning and returns the oldest rows when limited.
  """
  @spec recent_history(session_id(), keyword()) :: [Message.t()]
  def recent_history(session_id, opts \\ []), do: Store.recent_history(session_id, opts)

  @doc "Marks a session archived."
  @spec archive(SessionRow.t()) :: {:ok, SessionRow.t()} | {:error, Ecto.Changeset.t()}
  def archive(%SessionRow{} = session), do: Store.update_session(session, %{status: "archived"})

  @default_persona_name "default"
  # Resolved when read, not at compile time: a module attribute baked the build tree's
  # `_build/prod/lib/trinity/priv` into the release, where the priv directory is elsewhere,
  # and the first page of the headless release answered 500 on a fresh data directory (slice
  # 061 AC6's probe). The Burrito binary hid it: its payload keeps the build tree's layout.
  @default_soul_relative "personas/default/SOUL.md"

  @doc """
  The persona new sessions belong to: the row named `default`, created on first use. Slice
  013 added it so the chat can open a session; slice 030 seeds it from
  `priv/personas/default/SOUL.md` (the soul, and the persona rule that lets the `memory` tool
  write without asking) when the row is created or when its soul is still empty, so an
  install from before 030 gets the same seed on its next boot. A soul the owner has edited is
  never overwritten.
  """
  @spec default_persona() :: Persona.t()
  def default_persona do
    case Store.get_persona_by_name(@default_persona_name) do
      nil ->
        case Store.insert_persona(Map.put(default_seed(), :name, @default_persona_name)) do
          {:ok, persona} -> persona
          # Two callers raced; the unique index let one through, and it is the row.
          {:error, _} -> Store.get_persona_by_name(@default_persona_name)
        end

      %Persona{soul: soul} = persona when soul in [nil, ""] ->
        {:ok, seeded} = Store.update_persona(persona, default_seed())
        seeded

      persona ->
        persona
    end
  end

  @doc "The default persona's seed: the SOUL file and the settings it ships with."
  # sobelow_skip reason: Traversal.FileModule: the path is this application's priv directory
  # plus a constant, never a request's (resolved at read time since slice 061's fix).
  @sobelow_skip ["Traversal.FileModule"]
  @spec default_seed() :: map()
  def default_seed do
    %{
      soul: File.read!(Path.join(:code.priv_dir(:trinity), @default_soul_relative)),
      settings: %{"permissions" => %{"memory" => "allow"}}
    }
  end

  @doc "Every persona, by name (slice 030)."
  @spec list_personas() :: [Persona.t()]
  def list_personas, do: Store.list_personas()

  @doc "A persona by id, or nil."
  @spec get_persona(String.t()) :: Persona.t() | nil
  def get_persona(id), do: Store.get_persona(id)

  @doc "Updates a persona (slice 030)."
  @spec update_persona(Persona.t(), map()) :: {:ok, Persona.t()} | {:error, Ecto.Changeset.t()}
  def update_persona(%Persona{} = persona, attrs), do: Store.update_persona(persona, attrs)

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

  @doc """
  Sets the session's project root (slice 033): an existing directory, expanded, or nil to
  clear it. The next turn's tools work there and its AGENTS.md is read.
  """
  @spec set_project_root(session_id(), String.t() | nil) ::
          {:ok, SessionRow.t()} | {:error, term()}
  def set_project_root(session_id, nil) do
    with %SessionRow{} = session <- Store.get_session(session_id) || {:error, :no_session},
         do: Store.update_session(session, %{project_root: nil})
  end

  def set_project_root(session_id, root) when is_binary(root) do
    expanded = Path.expand(root)

    with true <- File.dir?(expanded) || {:error, {:not_a_directory, expanded}},
         %SessionRow{} = session <- Store.get_session(session_id) || {:error, :no_session},
         do: Store.update_session(session, %{project_root: expanded})
  end

  @doc "A message by id (slice 032: the memory page's provenance link)."
  @spec get_message(String.t()) :: Message.t() | nil
  def get_message(id), do: Store.get_message(id)

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
