# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Observer do
  @moduledoc """
  Fills the semantic tier after a turn (slice 032). The session hands the completed turn's
  messages to `observe/2`, which runs `run/2` under `Trinity.Memory.TaskSupervisor` so the
  session is idle at once and a crash here is this task's alone. `run/2` asks the session's
  own model (`Trinity.LLM.generate_object/3`, the one the operator chose for the conversation:
  no text goes anywhere new, NOTES decision 5) for 0 to 3 durable facts, preferences or
  decisions, embeds them in one batch, drops each whose cosine to a memory already in the
  session's scope chain is at or over the dedupe threshold (0.92, `dedupe_cosine:`) or to
  one earlier in the same batch, and inserts the rest as `semantic` rows in the persona's
  scope with the source message, the model's confidence and a row in the change log
  (`by: "observer"`).

  Off, and nothing runs, when the tier is off (`Trinity.Memory.Semantic.status/0`), when the
  session has no persona, or when `config :trinity, :memory, observer: false` (the test
  suite's default: the AC3 test calls `run/2` itself).
  """

  alias Trinity.LLM
  alias Trinity.LLM.Request
  alias Trinity.Memory.{AlwaysOn, Embedder, Entry, Semantic}

  require Logger

  @default_dedupe 0.92
  @max_memories 3

  @schema %{
    "type" => "object",
    "properties" => %{
      "memories" => %{
        "type" => "array",
        "maxItems" => @max_memories,
        "items" => %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string", "enum" => ["fact", "preference", "decision"]},
            "body" => %{"type" => "string"},
            "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
          },
          "required" => ["kind", "body", "confidence"]
        }
      }
    },
    "required" => ["memories"]
  }

  @typedoc "What the session hands over: its id, its persona and its model."
  @type turn :: %{session_id: String.t(), persona_id: String.t() | nil, model: String.t() | nil}

  @typedoc "A message of the turn, as the session's history carries it."
  @type message :: %{id: String.t(), role: String.t(), content: String.t()}

  @doc "The JSON Schema the model answers with."
  @spec schema() :: map()
  def schema, do: @schema

  @doc "True when the observer will run for this turn."
  @spec on?(turn()) :: boolean()
  def on?(%{persona_id: persona_id}) do
    is_binary(persona_id) and
      Keyword.get(Application.get_env(:trinity, :memory, []), :observer, true) == true and
      Semantic.on?()
  end

  @doc "Runs `run/2` under the memory task supervisor; `:off` when the observer is off."
  @spec observe(turn(), [message()]) :: {:ok, pid()} | :off
  def observe(turn, messages) do
    if on?(turn) do
      Task.Supervisor.start_child(Trinity.Memory.TaskSupervisor, fn -> run(turn, messages) end)
    else
      :off
    end
  end

  @doc """
  Extracts, dedupes and stores; synchronous. Returns the entries inserted, `:off`, or the
  model's error. The dedupe threshold is `dedupe_cosine:` in `config :trinity, :memory`.
  """
  @spec run(turn(), [message()]) :: {:ok, [Entry.t()]} | :off | {:error, term()}
  def run(%{persona_id: persona_id, session_id: session_id} = turn, messages) do
    with true <- on?(turn) || :off,
         {:ok, proposed} <- extract(turn, messages),
         {:ok, vectors} <- Embedder.embed(Enum.map(proposed, & &1.body)) do
      source = source_id(messages)

      inserted =
        proposed
        |> Enum.zip(vectors)
        |> dedupe(persona_id, AlwaysOn.chain(persona_id, session_id))
        |> Enum.flat_map(fn {m, v} -> insert(m, v, persona_id, session_id, source) end)

      {:ok, inserted}
    else
      :off -> :off
      {:error, reason} -> {:error, reason}
    end
  end

  # Drops a proposal whose vector is within the threshold of a memory in the chain or of one
  # kept earlier in this batch; order preserved.
  defp dedupe(pairs, persona_id, chain) do
    threshold =
      Keyword.get(Application.get_env(:trinity, :memory, []), :dedupe_cosine, @default_dedupe)

    {kept, _} =
      Enum.reduce(pairs, {[], []}, fn {m, v}, {kept, seen} ->
        if duplicate?(persona_id, chain, v, seen, threshold),
          do: {kept, seen},
          else: {[{m, v} | kept], [v | seen]}
      end)

    Enum.reverse(kept)
  end

  defp insert(m, vector, persona_id, session_id, source) do
    attrs = %{
      persona_id: persona_id,
      scope: AlwaysOn.persona_scope(persona_id),
      key: key(m.body),
      body: m.body,
      source_message_id: source,
      confidence: m.confidence
    }

    case Semantic.add(attrs, by: "observer", session_id: session_id, vector: vector) do
      {:ok, entry} ->
        [entry]

      {:error, reason} ->
        Logger.debug("memory: observer skipped #{inspect(m.body)}: #{inspect(reason)}")
        []
    end
  end

  @doc "The key a body gets: its first words as a slug and six hex digits of its digest, so two wordings never collide and the same wording always meets `:exists`."
  @spec key(String.t()) :: String.t()
  def key(body) do
    slug =
      body
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 6)
    if slug == "", do: "m-" <> digest, else: slug <> "-" <> digest
  end

  # The turn, with roles, as the model reads it. Tool rows are long and rarely durable:
  # named, not quoted.
  defp extract(%{model: model, session_id: session_id}, messages) do
    transcript =
      Enum.map_join(messages, "\n\n", fn
        %{role: "tool"} = m -> "[tool result: #{String.slice(m.content, 0, 200)}]"
        m -> "#{m.role}: #{String.slice(m.content, 0, 4_000)}"
      end)

    request =
      Request.new!(%{
        model: model,
        system:
          "You watch a conversation between a person and their personal agent and note what is " <>
            "worth remembering weeks from now: durable facts about the person or their work, their " <>
            "preferences, and decisions they made. List 0 to #{@max_memories}. Skip anything transient, " <>
            "anything about the agent itself, and anything a stranger would already know. Each memory " <>
            "is one sentence in the third person, and confidence is how sure you are it is durable " <>
            "and true (0 to 1). Invent nothing; an empty list is a fine answer.",
        messages: [%{role: "user", content: transcript}]
      })

    case LLM.generate_object(request, @schema, session_id: session_id) do
      {:ok, %{"memories" => memories}} when is_list(memories) ->
        {:ok, memories |> Enum.flat_map(&clean/1) |> Enum.take(@max_memories)}

      {:ok, other} ->
        {:error, {:no_memories, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clean(%{"body" => body} = m) when is_binary(body) do
    body = body |> String.trim() |> String.slice(0, 4_000)

    confidence =
      case m["confidence"] do
        n when is_number(n) -> n |> max(0) |> min(1) |> Kernel.*(1.0)
        _ -> 0.5
      end

    if body == "", do: [], else: [%{body: body, confidence: confidence, kind: m["kind"]}]
  end

  defp clean(_), do: []

  defp duplicate?(persona_id, chain, vector, seen, threshold) do
    Enum.any?(seen, &(Embedder.cosine(&1, vector) >= threshold)) or
      Semantic.near(persona_id, chain, vector, threshold) != nil
  end

  # Provenance: the assistant's last message of the turn, else the user's.
  defp source_id(messages) do
    case Enum.reverse(messages) do
      [] -> nil
      rev -> (Enum.find(rev, &(&1.role == "assistant")) || hd(rev)).id
    end
  end
end
