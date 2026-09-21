# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Retriever do
  @moduledoc """
  Hybrid recall (slice 032): what in the past is relevant to a query. Two ranked lists are
  fused by reciprocal rank (`1 / (60 + rank)`, summed for an item in both): the vector
  search over the persona's semantic memories in the session's scope chain (M6: never
  wider) and the full-text search of 031 over the persona's past messages (the current
  session's own rows are the history already and are left out). A recency decay then
  scales each fused score by `0.5 + 0.5 * 2^(-age / 30 days)`, age being the time since a
  memory was last used (or inserted) or a message was written: an old hit keeps at least
  half its score, so it is demoted below a recent one of the same rank, never lost.

  A vector search always has `k` nearest rows, however far; a memory enters the vector list
  only at a cosine of `recall_min_cosine:` (0.3) or more, the slice's own "unrelated" line
  (AC2: the unrelated pair measures 0.062 on the local model, the related one 0.858), so a
  question about nothing the person ever said recalls nothing.

  When the semantic tier is off, the vector list is empty and recall is the full-text list
  alone: 031 keeps working (NOTES decision 3). Memories that come back are marked used.
  """

  alias Trinity.Memory.{AlwaysOn, Embedder, Search, Semantic, VectorStore}

  @rrf_k 60
  @half_life_days 30
  @default_k 8
  @default_min_cosine 0.3

  @typedoc "A fused hit: a semantic memory or a past message, with the fused score and which lists found it."
  @type hit :: %{
          kind: :memory | :message,
          id: String.t(),
          text: String.t(),
          at: DateTime.t(),
          score: float(),
          found_by: [:vector | :fts],
          ref: map()
        }

  @doc """
  The `k` (#{@default_k}) most relevant hits for a query, best first. `opts`: `k:`,
  `now:` (the decay's reference), `touch:` (mark memory hits used; true).
  """
  @spec relevant(String.t(), String.t() | nil, String.t(), keyword()) :: [hit()]
  def relevant(persona_id, session_id, query, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    depth = max(k * 3, 20)

    vector = vector_hits(persona_id, session_id, query, depth)
    fts = fts_hits(persona_id, session_id, query, depth)

    hits =
      [{:vector, vector}, {:fts, fts}]
      |> Enum.reduce(%{}, fn {source, list}, acc -> fuse(acc, source, list) end)
      |> Map.values()
      |> Enum.map(&%{&1 | score: &1.score * decay(&1.at, now)})
      |> Enum.sort_by(&{-&1.score, &1.id})
      |> Enum.take(k)

    if Keyword.get(opts, :touch, true) do
      Semantic.touch(for %{kind: :memory, id: id} <- hits, do: id)
    end

    hits
  end

  @doc "The block the prompt carries: `## Relevant memories`, one line a hit; `\"\"` for none."
  @spec render([hit()]) :: String.t()
  def render([]), do: ""

  def render(hits) do
    "## Relevant memories\n" <>
      Enum.map_join(hits, "\n", fn
        %{kind: :memory, at: at, text: text} ->
          "- (remembered #{Calendar.strftime(at, "%Y-%m-%d")}) #{one_line(text)}"

        %{kind: :message, at: at, text: text, ref: ref} ->
          "- (#{ref.role} in \"#{ref.session_title || "untitled"}\", #{Calendar.strftime(at, "%Y-%m-%d")}) #{one_line(text)}"
      end)
  end

  @doc "The reciprocal-rank contribution of a rank (1-based)."
  @spec rrf(pos_integer()) :: float()
  def rrf(rank), do: 1 / (@rrf_k + rank)

  @doc "The recency factor: 1 now, 0.75 at one half-life, never under 0.5."
  @spec decay(DateTime.t(), DateTime.t()) :: float()
  def decay(at, now) do
    age_days = max(DateTime.diff(now, at, :second), 0) / 86_400
    0.5 + 0.5 * :math.pow(2, -age_days / @half_life_days)
  end

  # One list into the fused map: a first sighting takes its rank's share, a second adds it.
  defp fuse(acc, source, list) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {hit, rank}, acc ->
      first = %{hit | score: rrf(rank), found_by: [source]}
      again = &%{&1 | score: &1.score + rrf(rank), found_by: &1.found_by ++ [source]}
      Map.update(acc, {hit.kind, hit.id}, first, again)
    end)
  end

  defp vector_hits(persona_id, session_id, query, depth) do
    with true <- Semantic.on?(),
         {:ok, [vector]} <- Embedder.embed([query]) do
      chain = AlwaysOn.chain(persona_id, session_id)

      floor =
        Keyword.get(
          Application.get_env(:trinity, :memory, []),
          :recall_min_cosine,
          @default_min_cosine
        )

      vector
      |> VectorStore.search(depth, Semantic.filter(persona_id, chain))
      |> Enum.filter(&(&1.score >= floor))
      |> Enum.map(fn %{entry: e, score: s} ->
        %{
          kind: :memory,
          id: e.id,
          text: e.body,
          at: e.last_used_at || e.inserted_at,
          score: s,
          found_by: [],
          ref: %{key: e.key, scope: e.scope, source_message_id: e.source_message_id, cosine: s}
        }
      end)
    else
      _ -> []
    end
  end

  defp fts_hits(persona_id, session_id, query, depth) do
    query
    |> Search.messages(limit: min(depth + 20, 100), persona_id: persona_id)
    |> Enum.reject(&(&1.session_id == session_id))
    |> Enum.take(depth)
    |> Enum.map(fn h ->
      %{
        kind: :message,
        id: h.message_id,
        text: h.snippet,
        at: h.inserted_at,
        score: h.rank,
        found_by: [],
        ref: %{session_id: h.session_id, session_title: h.session_title, role: h.role, seq: h.seq}
      }
    end)
  end

  defp one_line(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 300)
end
