# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Search do
  @moduledoc """
  Full-text search over every message (slice 031). SQLite: the `messages_fts` FTS5 table,
  porter stemming, `bm25()` order, `snippet()`; Postgres: the generated `content_tsv` column,
  `plainto_tsquery('english')`, `ts_rank`, `ts_headline`. Same shape of hit either way, so the
  tool and the page do not know which database they run on.

  The query text is bound as a parameter and never spliced into SQL. On SQLite every term is
  additionally quoted for FTS5, so a user's `"`, `*`, `-` or `OR` is text to find, not an
  operator; the search is "all these words", stemmed, in any order. Stemming is a suffix
  operation: "running" and "runs" meet at "run", and "ran" does not (NOTES.md, fact 2).

  Schemaless queries on purpose: Memory depends on the core and LLM, never on Sessions
  (docs/01), so the tables are named here and the ids are cast through `Trinity.UUID`.
  """

  import Ecto.Query

  alias Trinity.Repo

  @default_limit 20
  @max_limit 100

  # The adapter is fixed at compile time (config/config.exs, slice 010), so the two databases'
  # query shapes are compiled in, not chosen at run time; the postgres job proves the other.
  @adapter Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)

  @type hit :: %{
          message_id: String.t(),
          session_id: String.t(),
          session_title: String.t() | nil,
          seq: non_neg_integer(),
          role: String.t(),
          snippet: String.t(),
          inserted_at: DateTime.t(),
          rank: float()
        }

  @doc """
  Ranked hits for `query`. Options: `limit:` (#{@default_limit}, at most #{@max_limit}), `role:`
  (a message role), `persona_id:`, `since:` and `until:` (`DateTime`, on the message's
  `inserted_at`). An empty or all-punctuation query is no hits.
  """
  @spec messages(String.t(), keyword()) :: [hit()]
  def messages(query, opts \\ []) when is_binary(query) do
    case terms(query) do
      [] -> []
      terms -> terms |> build(opts) |> Repo.all() |> Enum.map(&to_hit/1)
    end
  end

  @doc "The words of a query, punctuation dropped; the population FTS5 and tsquery both receive."
  @spec terms(String.t()) :: [String.t()]
  def terms(query) do
    query
    |> String.split(~r/[^\p{L}\p{N}_']+/u, trim: true)
    |> Enum.map(&String.replace(&1, "'", ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(32)
  end

  @doc "Rebuilds the index from `messages`; on Postgres the column is generated and this reports so."
  @spec reindex() :: {:ok, :rebuilt | :generated_column}
  if @adapter == Ecto.Adapters.SQLite3 do
    def reindex do
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM messages_fts")

        Repo.query!(
          "INSERT INTO messages_fts(rowid, content, session_id, message_id) SELECT rowid, content, session_id, id FROM messages"
        )

        Repo.query!("INSERT INTO messages_fts(messages_fts) VALUES('optimize')")
      end)

      {:ok, :rebuilt}
    end
  else
    def reindex, do: {:ok, :generated_column}
  end

  defp build(terms, opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    base()
    |> match(terms)
    |> filter(:role, opts[:role])
    |> filter(:persona_id, opts[:persona_id])
    |> filter(:since, opts[:since])
    |> filter(:until, opts[:until])
    |> limit(^limit)
  end

  defp base do
    from(m in "messages",
      join: s in "sessions",
      on: s.id == m.session_id,
      select: %{
        message_id: type(m.id, Trinity.UUID),
        session_id: type(m.session_id, Trinity.UUID),
        session_title: s.title,
        seq: m.seq,
        role: m.role,
        inserted_at: type(m.inserted_at, :utc_datetime_usec),
        persona_id: type(s.persona_id, Trinity.UUID)
      }
    )
  end

  # SQLite: every term quoted for FTS5 (a double quote inside is doubled), joined by spaces,
  # which FTS5 reads as AND; the whole string is one bound parameter.
  if @adapter == Ecto.Adapters.SQLite3 do
    defp match(query, terms) do
      needle = Enum.map_join(terms, " ", &("\"" <> String.replace(&1, "\"", "\"\"") <> "\""))

      from([m, s] in query,
        join: f in "messages_fts",
        on: f.rowid == m.rowid,
        where: fragment("messages_fts MATCH ?", ^needle),
        order_by: fragment("bm25(messages_fts)"),
        select_merge: %{
          snippet: fragment("snippet(messages_fts, 0, '[', ']', '…', 12)"),
          rank: fragment("bm25(messages_fts)")
        }
      )
    end
  else
    defp match(query, terms) do
      needle = Enum.join(terms, " ")

      from([m, s] in query,
        where: fragment("? @@ plainto_tsquery('english', ?)", m.content_tsv, ^needle),
        order_by: [
          desc: fragment("ts_rank(?, plainto_tsquery('english', ?))", m.content_tsv, ^needle)
        ],
        select_merge: %{
          snippet:
            fragment(
              "ts_headline('english', ?, plainto_tsquery('english', ?), 'StartSel=[, StopSel=], MaxWords=12, MinWords=6')",
              m.content,
              ^needle
            ),
          rank: fragment("ts_rank(?, plainto_tsquery('english', ?))", m.content_tsv, ^needle)
        }
      )
    end
  end

  defp filter(query, _key, nil), do: query
  defp filter(query, :role, role), do: from([m, s] in query, where: m.role == ^role)

  defp filter(query, :persona_id, id),
    do: from([m, s] in query, where: s.persona_id == type(^id, Trinity.UUID))

  defp filter(query, :since, at), do: from([m, s] in query, where: m.inserted_at >= ^at)
  defp filter(query, :until, at), do: from([m, s] in query, where: m.inserted_at <= ^at)

  defp to_hit(row) do
    row
    |> Map.delete(:persona_id)
    |> Map.update!(:rank, &(&1 * 1.0))
  end
end
