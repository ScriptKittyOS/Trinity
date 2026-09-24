# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Delegate do
  @moduledoc """
  `delegate`: hand a self-contained brief to a child session and get its result back (slice 080).

  Risk `:read`, effect `:none`, because delegating is not itself an effect. That deserves stating
  rather than assuming, since it looks like the opposite: **the child's own work is not covered by
  this tool's tier.** Every tool the child calls passes the same permission gate and leaves the
  same receipts as it would in the parent, so delegation cannot be used to launder a `:destructive`
  call through a `:read` one. What the tool spends without asking is tokens and time, and that is
  what the budget bounds.

  ## What a brief has to contain

  The child sees the persona, the brief, and nothing else. It cannot see the parent's conversation,
  which is the whole reason to delegate: the parent's context stays its own. So a brief that says
  "summarise that" delegates a question the child cannot answer. The description below says so to
  the model in those words, because this is the mistake a model makes here and it makes it quietly.

  ## Why the result comes back as text

  The child returns its final assistant message, truncated. Returning the child's whole history
  would put back exactly the context the delegation removed, and returning a structured object
  would require the parent to have specified a schema it usually does not have. A parent that wants
  the detail gets a session id it can open.
  """

  @behaviour Trinity.Tools.Tool

  alias Trinity.Subagents
  alias Trinity.Tools.{Context, Untrusted}

  @max_briefs 5
  @max_timeout_ms 300_000

  @impl true
  def name, do: "delegate"

  @impl true
  def description,
    do:
      "Hands a self-contained brief to a subagent, which runs it in its own session and returns its answer. " <>
        "Use it for work that would fill this conversation with detail nobody needs to see again: reading a long " <>
        "file to answer one question, searching for something, trying an approach that may not pan out. " <>
        "The subagent CANNOT see this conversation, so the brief must stand alone: say what to do and include " <>
        "every fact it needs. A brief like 'summarise that' will fail, because it does not know what 'that' is. " <>
        "Give `briefs` (a list) instead of `brief` to run several at once; they are independent and must not " <>
        "depend on each other's results."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "brief" => %{
          "type" => "string",
          "description" =>
            "One self-contained instruction, including every fact the subagent needs"
        },
        "briefs" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "maxItems" => @max_briefs,
          "description" =>
            "Several independent self-contained instructions, run concurrently (at most #{@max_briefs})"
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1_000,
          "maximum" => @max_timeout_ms,
          "description" => "How long each subagent may take before it is stopped"
        }
      },
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read

  @impl true
  def effect, do: :none

  @impl true
  def execute(args, %Context{session_id: session_id}) do
    budget = budget(args)

    case briefs(args) do
      {:error, reason} ->
        {:error, reason}

      {:one, brief} ->
        case Subagents.delegate(session_id, brief, budget: budget) do
          {:ok, result} -> {:ok, untrusted(render_one(result), [result])}
          {:error, reason} -> {:error, reason}
        end

      {:many, list} ->
        results =
          Subagents.delegate_many(session_id, list, budget: budget, concurrency: @max_briefs)

        oks = for {:ok, r} <- results, do: r
        {:ok, untrusted(render_many(list, results), oks)}
    end
  end

  defp briefs(%{"brief" => b, "briefs" => l}) when is_binary(b) and is_list(l),
    do: {:error, "Give either brief or briefs, not both."}

  defp briefs(%{"briefs" => []}), do: {:error, "briefs was empty."}

  defp briefs(%{"briefs" => list}) when is_list(list) do
    cond do
      length(list) > @max_briefs -> {:error, "At most #{@max_briefs} briefs at once."}
      Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")) -> {:many, list}
      true -> {:error, "Every brief must be a non-empty string."}
    end
  end

  defp briefs(%{"brief" => brief}) when is_binary(brief) do
    if String.trim(brief) == "", do: {:error, "brief was empty."}, else: {:one, brief}
  end

  defp briefs(_), do: {:error, "Give brief or briefs."}

  defp budget(args) do
    case Map.get(args, "timeout_ms") do
      ms when is_integer(ms) -> %{timeout_ms: min(ms, @max_timeout_ms)}
      _ -> %{}
    end
  end

  # The child's answer re-enters the parent's prompt, and it was produced by a model reading
  # whatever the child read. It is untrusted for exactly the reason any tool result is (docs/07),
  # and being produced by "our own" subagent changes nothing about that.
  defp untrusted(text, results) do
    Untrusted.result(text,
      tool: name(),
      source_ref: "subagent:" <> Enum.map_join(results, ",", & &1.session_id),
      meta: %{
        "subagents" => length(results),
        "session_ids" => Enum.map(results, & &1.session_id)
      }
    )
  end

  defp render_one(%{status: :ok, text: text, session_id: id}),
    do: "Subagent #{short(id)} answered:\n\n#{text}"

  defp render_one(%{status: :budget, session_id: id, reason: reason}),
    do:
      "Subagent #{short(id)} ran out of its budget (#{inspect(reason)}) and was stopped. " <>
        "Anything it had written is in its own session; it did not finish."

  defp render_one(%{status: status, session_id: id, reason: reason}),
    do: "Subagent #{short(id)} did not complete (#{status}: #{inspect(reason)})."

  defp render_many(briefs, results) do
    briefs
    |> Enum.zip(results)
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn
      {{brief, {:ok, result}}, n} -> "#{n}. #{first_line(brief)}\n#{render_one(result)}"
      {{brief, {:error, reason}}, n} -> "#{n}. #{first_line(brief)}\nFailed: #{inspect(reason)}"
    end)
  end

  defp first_line(brief), do: brief |> String.split("\n") |> List.first() |> String.slice(0, 80)

  defp short(id), do: String.slice(id, 0, 8)
end
