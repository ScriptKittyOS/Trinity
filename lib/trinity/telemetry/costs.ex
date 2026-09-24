# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry.Costs do
  @moduledoc """
  What the model calls have cost, and whether a budget has been passed (slice 090).

  **This is a read, not a pipeline.** Slice 011 already writes a `usage_events` row per completed
  call with the cost computed from the model registry's price. Nothing here recomputes that, and
  nothing here is a telemetry handler: a handler that failed or was detached would silently stop
  the ledger, and a missing bill is worse than a missing chart. The events in
  `docs/telemetry.md` describe the same calls, and the dashboards read them, but the money is read
  from the rows.

  ## Budgets

  Configured rather than stored, because there is no settings table and inventing one for three
  numbers would be the larger change:

      config :trinity, :budgets, day: 5.0, session: 1.0, persona: 20.0

  A budget that is not configured is not enforced. `check/2` answers `:ok` or
  `{:over, spent, limit}` and emits `[:trinity, :budget, :exceeded]` when it is over, so the
  warning reaches a dashboard whether or not anything is blocking on it.

  **Blocking is separate from warning, and off by default.** `config :trinity, :budgets,
  block_when_over: true` makes the session refuse a new turn. It is off because a budget that
  silently stops an agent mid-task is a failure a person cannot diagnose from the outside, and the
  warning is what makes the number visible before it becomes a wall.
  """

  import Ecto.Query

  alias Trinity.Repo

  # The table, not the schema. `Trinity.LLM` is a sub-boundary that depends on `Trinity`, so a
  # module in `Trinity` naming `Trinity.LLM.Usage` would be a cycle and the compiler refuses it.
  # That refusal is right rather than inconvenient: this module reads a ledger, it does not use the
  # LLM's API, and every query here is an aggregate that needs no struct. The column names are the
  # contract, and the test asserts they still exist.
  @table "usage_events"

  @scopes [:day, :session, :persona]

  @doc "The scopes a budget can be set for."
  @spec scopes() :: [atom()]
  def scopes, do: @scopes

  @doc "Total cost in US dollars across every recorded call, optionally since a time."
  @spec total(keyword()) :: float()
  def total(opts \\ []) do
    @table
    |> since(opts[:since])
    |> select([u], sum(u.cost_usd))
    |> Repo.one()
    |> zero_if_nil()
  end

  @doc "Total cost for one session."
  @spec for_session(String.t()) :: float()
  def for_session(session_id) do
    @table
    |> where([u], u.session_id == ^session_id)
    |> select([u], sum(u.cost_usd))
    |> Repo.one()
    |> zero_if_nil()
  end

  @doc """
  Total cost for one persona, summed across its sessions.

  `usage_events` carries the session, not the persona, so this joins. Storing the persona on the
  usage row would make this a simpler query and a wrong one: a session's persona can change, and
  the cost belongs to the session that incurred it.
  """
  @spec for_persona(String.t()) :: float()
  def for_persona(persona_id) do
    from(u in @table,
      join: s in "sessions",
      on: s.id == u.session_id,
      where: s.persona_id == ^persona_id,
      select: sum(u.cost_usd)
    )
    |> Repo.one()
    |> zero_if_nil()
  end

  @doc "Total cost today, in UTC."
  @spec for_today() :: float()
  def for_today, do: total(since: DateTime.utc_now() |> DateTime.to_date() |> start_of_day())

  @doc "Totals by day, newest first, as `{date, cost}`."
  @spec by_day(pos_integer()) :: [{Date.t(), float()}]
  def by_day(days \\ 30) do
    since = Date.utc_today() |> Date.add(-days) |> start_of_day()

    @table
    |> where([u], u.inserted_at >= ^since)
    |> group_by([u], fragment("date(?)", u.inserted_at))
    |> select([u], {fragment("date(?)", u.inserted_at), sum(u.cost_usd)})
    |> Repo.all()
    |> Enum.map(fn {d, c} -> {to_date(d), zero_if_nil(c)} end)
    |> Enum.sort({:desc, Date})
  end

  @doc "Totals by model, largest first, as `{model_id, cost, calls}`."
  @spec by_model(keyword()) :: [{String.t(), float(), non_neg_integer()}]
  def by_model(opts \\ []) do
    @table
    |> since(opts[:since])
    |> group_by([u], u.model_id)
    |> select([u], {u.model_id, sum(u.cost_usd), count(u.id)})
    |> Repo.all()
    |> Enum.map(fn {m, c, n} -> {m, zero_if_nil(c), n} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc "The configured budget for a scope, or `nil` when none is set."
  @spec budget(atom()) :: float() | nil
  def budget(scope) when scope in @scopes do
    case Application.get_env(:trinity, :budgets, [])[scope] do
      n when is_number(n) -> n / 1
      _ -> nil
    end
  end

  @doc "Whether a new turn should be refused when a budget is passed. Off unless configured."
  @spec blocking?() :: boolean()
  def blocking?, do: Application.get_env(:trinity, :budgets, [])[:block_when_over] == true

  @doc """
  Whether a scope is over its budget, emitting the warning event when it is.

  `:ok` when no budget is set for the scope, because an unconfigured budget is not a budget of
  zero. That distinction matters: the alternative silently blocks every call on a fresh install.
  """
  @spec check(atom(), String.t() | nil) :: :ok | {:over, float(), float()}
  def check(scope, scope_id \\ nil)

  def check(scope, scope_id) when scope in @scopes do
    case budget(scope) do
      nil ->
        :ok

      limit ->
        spent = spent(scope, scope_id)

        if spent > limit do
          Trinity.Telemetry.budget_exceeded(scope, scope_id, spent, limit)
          {:over, spent, limit}
        else
          :ok
        end
    end
  end

  def check(_scope, _scope_id), do: :ok

  @doc "Every configured scope that is over, for a caller that wants the whole picture at once."
  @spec over(String.t() | nil, String.t() | nil) :: [{atom(), float(), float()}]
  def over(session_id \\ nil, persona_id \\ nil) do
    [{:day, nil}, {:session, session_id}, {:persona, persona_id}]
    |> Enum.filter(fn {scope, id} -> scope == :day or id != nil end)
    |> Enum.flat_map(fn {scope, id} ->
      case check(scope, id) do
        {:over, spent, limit} -> [{scope, spent, limit}]
        :ok -> []
      end
    end)
  end

  defp spent(:day, _), do: for_today()
  defp spent(:session, id) when is_binary(id), do: for_session(id)
  defp spent(:persona, id) when is_binary(id), do: for_persona(id)
  defp spent(_, _), do: 0.0

  defp since(query, nil), do: query
  defp since(query, %DateTime{} = at), do: where(query, [u], u.inserted_at >= ^at)

  defp start_of_day(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)

  defp zero_if_nil(nil), do: 0.0
  defp zero_if_nil(%Decimal{} = d), do: Decimal.to_float(d)
  defp zero_if_nil(n) when is_number(n), do: n / 1
end
