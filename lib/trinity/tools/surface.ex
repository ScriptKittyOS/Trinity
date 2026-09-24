# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Surface do
  @moduledoc """
  The baseline: each tool's definition as this machine first saw it, or as the owner last accepted
  it (slice 029).

  A server can change what its tools say at any time, and nothing in the protocol requires it to
  announce that it has. The baseline is what makes a change visible: without one, the second listing
  is indistinguishable from the first.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Trinity.Repo
  alias Trinity.Tools.DefinitionDigest

  @type t :: %__MODULE__{}

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  schema "tool_surfaces" do
    field :server, :string
    field :tool, :string
    field :digest, :string
    field :definition, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :pending_definition, :map
    field :pending_digest, :string
    field :pending_since, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The baseline for one tool of one server, or nil."
  @spec get(String.t(), String.t()) :: t() | nil
  def get(server, tool), do: Repo.get_by(__MODULE__, server: server, tool: tool)

  @doc "Every baseline for a server, oldest first."
  @spec for_server(String.t()) :: [t()]
  def for_server(server) do
    Repo.all(from s in __MODULE__, where: s.server == ^server, order_by: [asc: s.first_seen_at])
  end

  @doc """
  Records a first sighting. Does nothing when a baseline already exists, so a re-list of an
  unchanged surface does not rewrite the row and `first_seen_at` keeps meaning what it says.
  """
  @spec record_first_sighting(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def record_first_sighting(server, tool, listed) do
    case get(server, tool) do
      nil -> insert(server, tool, listed, nil)
      existing -> {:ok, existing}
    end
  end

  @doc """
  Accepts a definition as the new baseline, keeping `first_seen_at` and stamping `accepted_at`.

  A tool that has been present for months and changed today is not the same thing as a tool that
  appeared today, and the owner deciding about the first should still be able to tell.
  """
  @spec accept(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def accept(server, tool, listed) do
    now = DateTime.utc_now()

    case get(server, tool) do
      nil ->
        insert(server, tool, listed, now)

      existing ->
        existing
        |> change(%{
          digest: DefinitionDigest.of(listed),
          definition: DefinitionDigest.canonical_form(listed),
          accepted_at: now,
          pending_definition: nil,
          pending_digest: nil,
          pending_since: nil
        })
        |> Repo.update()
    end
  end

  @doc """
  Records a definition that drifted, for the owner to decide about.

  Overwrites any previous pending definition: a server that changes a tool twice before anyone
  looks has simply changed it, and the owner should be shown where it stands now rather than a
  history of the server's edits. `pending_since` keeps the time of the first unresolved change.
  """
  @spec record_drift(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def record_drift(server, tool, listed) do
    case get(server, tool) do
      nil ->
        record_first_sighting(server, tool, listed)

      existing ->
        existing
        |> change(%{
          pending_definition: DefinitionDigest.canonical_form(listed),
          pending_digest: DefinitionDigest.of(listed),
          pending_since: existing.pending_since || DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  @doc "Every tool with an outstanding change, oldest first. This is what the owner is shown."
  @spec drifting() :: [t()]
  def drifting do
    Repo.all(
      from s in __MODULE__, where: not is_nil(s.pending_digest), order_by: [asc: s.pending_since]
    )
  end

  @doc """
  Dismisses an outstanding change without accepting it.

  The baseline stands, so the tool stays held. The next listing detects the same drift and puts it
  back, which is the point: dismissing is not deciding, and a server that has not reverted has not
  been forgiven.
  """
  @spec dismiss(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def dismiss(server, tool) do
    case get(server, tool) do
      nil ->
        {:error, :not_found}

      existing ->
        existing
        |> change(%{pending_definition: nil, pending_digest: nil, pending_since: nil})
        |> Repo.update()
    end
  end

  @doc "Removes a server's baselines, for a server the owner has removed."
  @spec forget_server(String.t()) :: {non_neg_integer(), nil}
  def forget_server(server), do: Repo.delete_all(from s in __MODULE__, where: s.server == ^server)

  defp insert(server, tool, listed, accepted_at) do
    now = DateTime.utc_now()

    %__MODULE__{}
    |> change(%{
      server: server,
      tool: tool,
      digest: DefinitionDigest.of(listed),
      definition: DefinitionDigest.canonical_form(listed),
      first_seen_at: now,
      accepted_at: accepted_at
    })
    |> unique_constraint([:server, :tool])
    |> Repo.insert()
  end
end
