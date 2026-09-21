# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.AlwaysOn do
  @moduledoc """
  The always-on memory tiers (slice 030): `profile` (who the person is) and `always_on` (what
  Trinity keeps in mind), rendered as a deterministic block into every prompt of the persona.

  **Scopes.** A session reads its scope chain, `session:<id>`, `persona:<id>`, `global`, and
  nothing else: a memory written for one session is invisible to another until promoted
  (SLICE.md M6, AC7). Promotion is a change like any other, logged; through the `memory` tool
  it is an artifact effect with a receipt.

  **Every write is logged** in `memory_changes` with the body before and after and who wrote
  it (`tool`, `ui`, `consolidator`). After a write the budget is checked and, over it,
  `Trinity.Memory.Consolidator.run/2` is asked to bring the tiers under it.

  **The snapshot** is computed once per session start and on explicit refresh; the Session
  keeps it in state, so a mid-session edit takes effect next session or on refresh.
  """

  import Ecto.Query

  alias Trinity.Memory.{Budget, Change, Entry}
  alias Trinity.Repo

  @type scope :: String.t()
  @type write_opts :: [
          by: String.t(),
          session_id: String.t() | nil,
          proposal_id: String.t() | nil
        ]

  @doc "The scope chain a session reads, innermost first."
  @spec chain(String.t(), String.t() | nil) :: [scope()]
  def chain(persona_id, nil), do: ["persona:" <> persona_id, "global"]

  def chain(persona_id, session_id),
    do: ["session:" <> session_id, "persona:" <> persona_id, "global"]

  @doc "The persona scope."
  @spec persona_scope(String.t()) :: scope()
  def persona_scope(persona_id), do: "persona:" <> persona_id

  @doc "A session's scope."
  @spec session_scope(String.t()) :: scope()
  def session_scope(session_id), do: "session:" <> session_id

  @doc "The entries a session sees: its chain, always-on tiers, sorted by tier then key."
  @spec entries(String.t(), String.t() | nil) :: [Entry.t()]
  def entries(persona_id, session_id) do
    scopes = chain(persona_id, session_id)

    from(e in Entry,
      where:
        e.persona_id == ^persona_id and e.scope in ^scopes and e.tier in ^Entry.always_on_tiers(),
      order_by: [e.tier, e.key]
    )
    |> Repo.all()
    |> Enum.sort_by(&{tier_rank(&1.tier), &1.key})
  end

  @doc "Every always-on entry of a persona, over every scope (the pages and the consolidator)."
  @spec all(String.t()) :: [Entry.t()]
  def all(persona_id) do
    from(e in Entry, where: e.persona_id == ^persona_id and e.tier in ^Entry.always_on_tiers())
    |> Repo.all()
    |> Enum.sort_by(&{tier_rank(&1.tier), &1.scope, &1.key})
  end

  @doc """
  The block the prompt carries: profile then always-on, one `- key: body` per entry, sorted, or
  `""` when there is nothing. Deterministic for the same rows.
  """
  @spec snapshot(String.t(), String.t() | nil) :: String.t()
  def snapshot(persona_id, session_id) do
    persona_id |> entries(session_id) |> render()
  end

  @doc "Renders entries as the snapshot block."
  @spec render([Entry.t()]) :: String.t()
  def render([]), do: ""

  def render(entries) do
    entries
    |> Enum.group_by(& &1.tier)
    |> Enum.sort_by(fn {tier, _} -> tier_rank(tier) end)
    |> Enum.map_join("\n\n", fn {tier, es} ->
      heading = if tier == "profile", do: "## About the person", else: "## Always in mind"
      heading <> "\n" <> Enum.map_join(es, "\n", &"- #{&1.key}: #{&1.body}")
    end)
  end

  @doc "An entry by tier, scope and key."
  @spec get(String.t(), scope(), String.t()) :: Entry.t() | nil
  def get(tier, scope, key), do: Repo.get_by(Entry, tier: tier, scope: scope, key: key)

  @doc "Adds an entry (refused if the key exists in that tier and scope); logged; budget checked."
  @spec add(map(), write_opts()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t() | :exists}
  def add(attrs, opts) do
    attrs = Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)

    if get(attrs[:tier], attrs[:scope], attrs[:key]) do
      {:error, :exists}
    else
      with {:ok, entry} <- %Entry{} |> Entry.changeset(attrs) |> Repo.insert() do
        log(entry, "add", nil, entry.body, opts)
        after_write(entry.persona_id, opts)
        {:ok, entry}
      end
    end
  end

  @doc "Replaces an entry's body; logged; budget checked."
  @spec replace(Entry.t(), String.t(), write_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def replace(%Entry{} = entry, body, opts) do
    with {:ok, updated} <- entry |> Entry.changeset(%{body: body}) |> Repo.update() do
      log(updated, "replace", entry.body, body, opts)
      after_write(entry.persona_id, opts)
      {:ok, updated}
    end
  end

  @doc "Removes an entry; logged."
  @spec remove(Entry.t(), write_opts()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def remove(%Entry{} = entry, opts) do
    with {:ok, deleted} <- Repo.delete(entry) do
      log(entry, "remove", entry.body, nil, opts)
      {:ok, deleted}
    end
  end

  @doc "Moves an entry to another scope (a session's memory to the persona's, or to global); logged as a promotion."
  @spec promote(Entry.t(), scope(), write_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t() | :exists}
  def promote(%Entry{} = entry, to_scope, opts) do
    if get(entry.tier, to_scope, entry.key) do
      {:error, :exists}
    else
      with {:ok, moved} <- entry |> Entry.changeset(%{scope: to_scope}) |> Repo.update() do
        log(moved, "promote", entry.scope, to_scope, opts)
        {:ok, moved}
      end
    end
  end

  @doc "The change log of a persona, newest first (`limit:`)."
  @spec changes(String.t(), keyword()) :: [Change.t()]
  def changes(persona_id, opts \\ []) do
    from(c in Change,
      where: c.persona_id == ^persona_id,
      order_by: [desc: c.inserted_at],
      limit: ^Keyword.get(opts, :limit, 200)
    )
    |> Repo.all()
  end

  @doc "The change rows of one consolidation proposal."
  @spec changes_of_proposal(String.t()) :: [Change.t()]
  def changes_of_proposal(proposal_id),
    do: Repo.all(from c in Change, where: c.proposal_id == ^proposal_id, order_by: c.inserted_at)

  @doc false
  @spec log(Entry.t(), String.t(), String.t() | nil, String.t() | nil, write_opts()) :: Change.t()
  def log(%Entry{} = e, action, before, after_, opts) do
    Repo.insert!(%Change{
      persona_id: e.persona_id,
      action: action,
      tier: e.tier,
      scope: e.scope,
      key: e.key,
      before: before,
      after: after_,
      by: Keyword.get(opts, :by, "unknown"),
      session_id: Keyword.get(opts, :session_id),
      proposal_id: Keyword.get(opts, :proposal_id),
      inserted_at: DateTime.utc_now()
    })
  end

  # The consolidator runs after a write that leaves the persona over budget, unless the write
  # is the consolidator's own.
  defp after_write(persona_id, opts) do
    if Keyword.get(opts, :by) != "consolidator" and Budget.status(persona_id).over? do
      Trinity.Memory.Consolidator.run(persona_id, opts)
    end

    :ok
  end

  defp tier_rank("profile"), do: 0
  defp tier_rank("always_on"), do: 1
  defp tier_rank(_), do: 2

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
