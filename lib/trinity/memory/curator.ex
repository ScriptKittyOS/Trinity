# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Curator do
  @moduledoc """
  The memory curator (slice 050), a job on the `maintenance` queue the Cron plugin runs daily:
  an entry untouched for `stale_days` (30) is marked stale (`stale_at`; it is still recalled,
  and the pages show it as stale), one untouched for `archive_days` (90) is archived
  (`archived_at`; it leaves recall and stays in the row). Nothing is ever deleted here.
  "Untouched" is `last_used_at`, or `updated_at` when the entry was never used.

  Marking stale is a read the record keeps as one query receipt per persona on the memory
  scope; archiving is a write, and each entry archived is an effect receipt written by the
  curator itself (phase `done`, subject the entry), as slice 041's promotion writes its own:
  the membrane's runner is for tool calls, and this is not one. The thresholds are
  `config :trinity, :curator, stale_days:` and `archive_days:`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3_600]

  import Ecto.Query, only: [from: 2]

  alias Trinity.Memory.Entry
  alias Trinity.Receipts
  alias Trinity.Repo

  @default_stale_days 30
  @default_archive_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now =
      case Map.get(args, "now") do
        nil ->
          DateTime.utc_now()

        iso ->
          {:ok, at, _} = DateTime.from_iso8601(iso)
          at
      end

    {:ok, curate(now)}
  end

  @doc "Runs the curator once at `now`; returns the counts of entries marked stale and archived."
  @spec curate(DateTime.t()) :: %{stale: non_neg_integer(), archived: non_neg_integer()}
  def curate(now \\ DateTime.utc_now()) do
    stale_before = DateTime.add(now, -days(:stale_days, @default_stale_days), :day)
    archive_before = DateTime.add(now, -days(:archive_days, @default_archive_days), :day)

    archived =
      for entry <- untouched_before(archive_before), is_nil(entry.archived_at), reduce: 0 do
        n ->
          {:ok, _} = Repo.update(Ecto.Changeset.change(entry, archived_at: now))
          archive_receipt(entry, now)
          n + 1
      end

    stale =
      untouched_before(stale_before)
      |> Enum.filter(&(is_nil(&1.stale_at) and is_nil(&1.archived_at)))

    for entry <- stale, do: {:ok, _} = Repo.update(Ecto.Changeset.change(entry, stale_at: now))

    stale
    |> Enum.group_by(& &1.persona_id)
    |> Enum.each(fn {persona_id, entries} -> stale_receipt(persona_id, entries, now) end)

    %{stale: length(stale), archived: archived}
  end

  @doc "The chain scope the curator's receipts go to for a persona."
  @spec scope(String.t()) :: String.t()
  def scope(persona_id), do: "memory:" <> persona_id

  defp days(key, default),
    do: Application.get_env(:trinity, :curator, []) |> Keyword.get(key, default)

  defp untouched_before(cutoff) do
    Repo.all(
      from(e in Entry,
        where:
          (not is_nil(e.last_used_at) and e.last_used_at < ^cutoff) or
            (is_nil(e.last_used_at) and e.updated_at < ^cutoff)
      )
    )
  end

  defp stale_receipt(persona_id, entries, now) do
    Receipts.append(scope(persona_id), %{
      kind: "query",
      subject: %{
        "persona_id" => persona_id,
        "curator" => "stale",
        "entries" => Enum.map(entries, & &1.id),
        "at" => DateTime.to_iso8601(now)
      },
      decision: %{"ok" => true, "count" => length(entries)},
      subject_ref: "curator:stale:#{persona_id}:#{DateTime.to_iso8601(now)}",
      meta: %{}
    })
  end

  defp archive_receipt(entry, now) do
    Receipts.append(scope(entry.persona_id), %{
      kind: "effect",
      subject: %{
        "persona_id" => entry.persona_id,
        "entry_id" => entry.id,
        "tier" => entry.tier,
        "scope" => entry.scope,
        "key" => entry.key,
        "phase" => "done",
        "curator" => "archive",
        "at" => DateTime.to_iso8601(now)
      },
      decision: %{"outcome" => "archived", "by" => "curator"},
      subject_ref: "curator:archive:#{entry.id}",
      meta: %{}
    })
  end
end
