# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Learner do
  @moduledoc """
  What the owner's own decisions imply, spent on asking less often (slice 042).

  This is the connectome research report's A1 and A4, reshaped by the evidence rather than
  implemented as written. The report puts a learned recommendation at the arbitration point, beside
  the decision the owner is about to make. Three findings say that is the one place it must not go:

  * **Anchoring.** A recommendation shown before a person forms their own assessment moves the
    decision. Trinity's permission model rests entirely on that decision being independent of what
    the agent wants, so an anchor there is not a rough edge, it is an attack on the premise.
  * **Automation bias.** Accepting suggestions without scrutiny, and then ceasing to monitor.
  * **Approval fatigue.** Between 49% and 96% of safety alerts are dismissed in the clinical
    literature, and human intervention succeeds in 9% to 26% of cases even once a problem has
    surfaced. The cause is **volume**, so the intervention that helps reduces volume rather than
    annotating it.

  So the learned signal is spent on proposing a **rule**, reviewed in a calm moment, and on reporting
  **divergence** after the fact. Both are decisions about the population of future asks rather than
  nudges on a pending one. `test/trinity/permissions/learner_census_test.exs` asserts that nothing
  this module produces reaches an approval card, and that census is the reason the module exists in
  this shape.

  ## A proposal is unanimous or it is not a proposal

  A rule is proposed only when every decision for that tool agreed. One dissent and it becomes a
  divergence to look at instead, because a rule drawn from eleven allows and one deny would permit
  the case the owner refused. That is the whole of `AC3`: a proposal can never imply a permission
  broader than the decisions it was drawn from, and unanimity is what makes that true by
  construction rather than by arithmetic.

  ## It reads decisions, and writes nothing but proposals

  The source is the approvals table: rows the permission gate wrote when a person decided. The
  learner has no write path into policy state or the effect catalogue, which a test asserts. What it
  produces is a suggestion of a rule **the owner could have written by hand**, and accepting one
  writes it through `Trinity.Permissions.put_rule/1`, the ordinary path, with no second kind of rule
  anywhere in the tree.
  """

  import Ecto.Query

  alias Trinity.Permissions.Approval
  alias Trinity.Repo

  @default_threshold 5
  @decided ~w(allowed denied)

  @type proposal :: %{
          tool: String.t(),
          decision: String.t(),
          count: pos_integer(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t()
        }

  @type divergence :: %{
          tool: String.t(),
          counts: %{String.t() => pos_integer()},
          total: pos_integer()
        }

  @doc "How many consistent decisions before a rule is worth proposing."
  @spec threshold() :: pos_integer()
  def threshold do
    Application.get_env(:trinity, :permissions, [])
    |> Keyword.get(:proposal_threshold, @default_threshold)
  end

  @doc """
  The rules the owner's decisions imply, strongest first.

  A tool appears only when every decision for it agreed and there are at least `threshold/0` of them,
  and only when no rule already covers it: proposing what is already true is noise, and noise is what
  makes a person stop reading.
  """
  @spec proposals(keyword()) :: [proposal()]
  def proposals(opts \\ []) do
    minimum = Keyword.get(opts, :threshold, threshold())
    covered = existing_rule_tools()

    decided()
    |> Enum.group_by(& &1.tool)
    |> Enum.reject(fn {tool, _rows} -> tool in covered end)
    |> Enum.flat_map(&propose(&1, minimum))
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc """
  Tools whose decisions did not agree, with the counts.

  Read-only and reported after the fact, which is what makes it safe: a count of what has already
  been decided cannot anchor a decision that has already happened.
  """
  @spec divergences(keyword()) :: [divergence()]
  def divergences(_opts \\ []) do
    decided()
    |> Enum.group_by(& &1.tool)
    |> Enum.flat_map(fn {tool, rows} ->
      counts = Enum.frequencies_by(rows, & &1.status)

      if map_size(counts) > 1 do
        [%{tool: tool, counts: counts, total: length(rows)}]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.total, :desc)
  end

  defp propose({tool, rows}, minimum) do
    counts = Enum.frequencies_by(rows, & &1.status)

    with 1 <- map_size(counts),
         [{status, count}] <- Map.to_list(counts),
         true <- count >= minimum do
      times = rows |> Enum.map(& &1.inserted_at) |> Enum.sort(DateTime)

      [
        %{
          tool: tool,
          decision: rule_decision(status),
          count: count,
          first_seen: List.first(times),
          last_seen: List.last(times)
        }
      ]
    else
      _ -> []
    end
  end

  # The approvals vocabulary is `allowed`/`denied`; the rules vocabulary is `allow`/`deny`. Mapped
  # here rather than by trimming a letter somewhere, because two closed vocabularies that nearly
  # match are exactly where a silent mistranslation lives.
  defp rule_decision("allowed"), do: "allow"
  defp rule_decision("denied"), do: "deny"

  defp decided do
    Repo.all(
      from a in Approval,
        where: a.status in ^@decided,
        select: %{
          tool: a.tool,
          status: a.status,
          inserted_at: a.inserted_at
        }
    )
  end

  defp existing_rule_tools do
    Repo.all(from r in Trinity.Permissions.Rule, select: r.tool) |> MapSet.new()
  end
end
