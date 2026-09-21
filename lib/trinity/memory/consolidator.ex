# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Consolidator do
  @moduledoc """
  Brings a persona's always-on tiers back under the byte budget by consolidation, never by
  truncation (slice 030, AC3). Given every entry, the model (`Trinity.LLM.generate_object/3`
  with the persona's model) proposes a smaller set: merged, condensed, the same tiers and
  scopes, nothing invented. When the proposal fits the budget it is applied at once and every
  removal and change is logged with the proposal's id, so no entry leaves the tiers without a
  row in the log; when it does not fit, or the model answers nothing usable, the proposal is
  held `pending` for the owner, and the tiers stay as they are, over budget, until then.
  """

  import Ecto.Query

  alias Trinity.LLM
  alias Trinity.LLM.Request
  alias Trinity.Memory.{AlwaysOn, Budget, Entry, Proposal}
  alias Trinity.Repo

  require Logger

  @schema %{
    "type" => "object",
    "properties" => %{
      "entries" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "tier" => %{"type" => "string", "enum" => ["profile", "always_on"]},
            "scope" => %{"type" => "string"},
            "key" => %{"type" => "string"},
            "body" => %{"type" => "string"}
          },
          "required" => ["tier", "scope", "key", "body"]
        }
      }
    },
    "required" => ["entries"]
  }

  @doc "The JSON Schema the model answers with."
  @spec schema() :: map()
  def schema, do: @schema

  @doc """
  Runs one consolidation for a persona. Returns `{:applied, proposal}`, `{:pending, proposal}`
  or `{:error, reason}`; `opts` carry `session_id:` and `model:`.
  """
  @spec run(String.t(), keyword()) ::
          {:applied, Proposal.t()} | {:pending, Proposal.t()} | {:error, term()}
  def run(persona_id, opts \\ []) do
    entries = AlwaysOn.all(persona_id)
    before = Enum.sum(Enum.map(entries, &Entry.bytes/1))
    budget = Budget.bytes()

    case propose(persona_id, entries, budget, opts) do
      {:ok, proposed} ->
        after_bytes = Budget.bytes_of(proposed)
        status = if after_bytes <= budget and after_bytes < before, do: "applied", else: "pending"

        proposal =
          Repo.insert!(%Proposal{
            persona_id: persona_id,
            entries: %{"entries" => proposed},
            bytes_before: before,
            bytes_after: after_bytes,
            budget: budget,
            status: status,
            decided_at: if(status == "applied", do: DateTime.utc_now())
          })

        if status == "applied" do
          apply_entries(persona_id, entries, proposed, proposal.id, opts)
          {:applied, proposal}
        else
          {:pending, proposal}
        end

      {:error, reason} ->
        Logger.warning(
          "memory: consolidation for #{persona_id} produced no proposal: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Applies a pending proposal (the owner's decision on the memory page)."
  @spec apply_proposal(Proposal.t(), keyword()) :: {:ok, Proposal.t()} | {:error, term()}
  def apply_proposal(%Proposal{status: "pending"} = proposal, opts \\ []) do
    entries = AlwaysOn.all(proposal.persona_id)

    apply_entries(
      proposal.persona_id,
      entries,
      proposal.entries["entries"] || [],
      proposal.id,
      opts
    )

    proposal
    |> Ecto.Changeset.change(status: "applied", decided_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc "Rejects a pending proposal; the tiers stay as they are."
  @spec reject_proposal(Proposal.t()) :: {:ok, Proposal.t()} | {:error, term()}
  def reject_proposal(%Proposal{status: "pending"} = proposal),
    do:
      proposal
      |> Ecto.Changeset.change(status: "rejected", decided_at: DateTime.utc_now())
      |> Repo.update()

  @doc "Pending proposals of a persona, oldest first."
  @spec pending(String.t()) :: [Proposal.t()]
  def pending(persona_id),
    do:
      Repo.all(
        from p in Proposal,
          where: p.persona_id == ^persona_id and p.status == "pending",
          order_by: p.inserted_at
      )

  @doc "A proposal by id."
  @spec get(String.t()) :: Proposal.t() | nil
  def get(id), do: Repo.get(Proposal, id)

  # The model's proposal: entries as the object answers, cleaned to the shape the schema
  # promised (a scope the persona owns, a key the changeset accepts).
  defp propose(persona_id, entries, budget, opts) do
    listing = Enum.map_join(entries, "\n", &"- [#{&1.tier}] [#{&1.scope}] #{&1.key}: #{&1.body}")

    request =
      Request.new!(%{
        model: Keyword.get(opts, :model),
        system:
          "You maintain a small memory for a personal agent. The entries below use " <>
            "#{Enum.sum(Enum.map(entries, &Entry.bytes/1))} bytes and the budget is #{budget} bytes. " <>
            "Return a smaller set that keeps every fact that matters: merge entries that belong together, " <>
            "shorten bodies, drop only what is redundant. Keep each entry's tier and scope. Keys are short, " <>
            "lowercase, stable. Invent nothing.",
        messages: [%{role: "user", content: listing}]
      })

    case LLM.generate_object(request, @schema, session_id: Keyword.get(opts, :session_id)) do
      {:ok, %{"entries" => proposed}} when is_list(proposed) and proposed != [] ->
        {:ok, Enum.map(proposed, &clean(&1, persona_id))}

      {:ok, other} ->
        {:error, {:no_entries, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clean(e, persona_id) do
    %{
      "tier" => if(e["tier"] in Entry.always_on_tiers(), do: e["tier"], else: "always_on"),
      "scope" =>
        if(is_binary(e["scope"]) and e["scope"] != "",
          do: e["scope"],
          else: AlwaysOn.persona_scope(persona_id)
        ),
      "key" =>
        e["key"]
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_.-]+/, "-")
        |> String.slice(0, 64),
      "body" => to_string(e["body"])
    }
  end

  # The proposed set replaces the current one: an entry with the same tier, scope and key is
  # replaced when its body changed; one absent from the proposal is removed; one new in the
  # proposal is added. Each is a logged change carrying the proposal id.
  defp apply_entries(persona_id, current, proposed, proposal_id, opts) do
    by = [
      by: "consolidator",
      session_id: Keyword.get(opts, :session_id),
      proposal_id: proposal_id
    ]

    keyed = Map.new(proposed, &{{&1["tier"], &1["scope"], &1["key"]}, &1})

    for e <- current do
      case Map.get(keyed, {e.tier, e.scope, e.key}) do
        nil -> {:ok, _} = AlwaysOn.remove(e, by)
        %{"body" => body} when body != e.body -> {:ok, _} = AlwaysOn.replace(e, body, by)
        _ -> :unchanged
      end
    end

    existing = MapSet.new(current, &{&1.tier, &1.scope, &1.key})

    for p <- proposed, not MapSet.member?(existing, {p["tier"], p["scope"], p["key"]}) do
      {:ok, _} = AlwaysOn.add(Map.put(p, "persona_id", persona_id), by)
    end

    :ok
  end
end
