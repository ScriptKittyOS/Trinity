# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Recall do
  @moduledoc """
  `recall`: hybrid recall over the semantic tier and past conversations (slice 032,
  `Trinity.Memory.Retriever`). A read: risk `:read`, effect `:none`, so it runs without
  asking and leaves a query receipt. The hits are the person's own memories and history and
  come back as text the model reads; they are wrapped as untrusted all the same, as
  `session_search`'s are (docs/07: a tool result re-entering the prompt is data). When the
  semantic tier is off the answer says so and carries the full-text half alone.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Memory.{Retriever, Semantic}
  alias Trinity.Tools.{Context, Untrusted}

  @default_k 8
  @max_k 20

  @impl true
  def name, do: "recall"

  @impl true
  def description,
    do:
      "Recalls what is relevant to a question from long-term memory and past conversations: memories by meaning, messages by their words, fused and recent first. Returns at most `k` hits, each as `memory · when · text` or `session · when · role: …snippet…`. Use it before answering anything that depends on what this person told you in the past."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "What to recall, as a question or a phrase"
        },
        "k" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_k,
          "description" => "At most this many hits (default #{@default_k})"
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read

  @impl true
  def effect, do: :none

  @impl true
  def execute(%{"query" => query} = args, %Context{session_id: session_id, persona: persona}) do
    k = args |> Map.get("k", @default_k) |> min(@max_k)
    status = Semantic.status()

    hits =
      case persona do
        %{id: persona_id} -> Retriever.relevant(persona_id, session_id, query, k: k)
        _ -> []
      end

    text =
      case {hits, status} do
        {[], _} -> "Nothing recalled for #{inspect(query)}."
        {hits, _} -> Enum.map_join(hits, "\n", &line/1)
      end

    text =
      if status == :on,
        do: text,
        else: "(#{Semantic.describe(status)}; full-text hits only)\n" <> text

    meta = %{
      "query" => query,
      "hits" => length(hits),
      "k" => k,
      "semantic" => status == :on,
      "memory_hits" => Enum.count(hits, &(&1.kind == :memory))
    }

    {:ok, Untrusted.result(text, tool: name(), source_ref: "recall:" <> query, meta: meta)}
  end

  defp line(%{kind: :memory, at: at, text: text, ref: ref}),
    do: "memory #{ref.key} · #{Calendar.strftime(at, "%Y-%m-%d")} · #{text}"

  defp line(%{kind: :message, at: at, text: text, ref: ref}) do
    title = ref.session_title || "untitled"

    "#{title} (#{ref.session_id}) · #{Calendar.strftime(at, "%Y-%m-%d %H:%M")} · #{ref.role}: #{text}"
  end
end
