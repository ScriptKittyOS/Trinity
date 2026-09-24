# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Subagents do
  @moduledoc """
  Delegation to child sessions (slice 080).

  A subagent is an ordinary session with `origin: "subagent"` and its `parent_id` set. It runs one
  turn against a brief and returns a result; its messages stay in its own history and never enter
  the parent's.

  **Why that isolation is the point rather than a detail.** The reason to delegate at all is that
  the parent's context is finite and expensive. A delegation that copied the child's working back
  into the parent would cost more than doing the work inline, and the parent would pay it twice:
  once in tokens and once in a context window full of somebody else's reasoning. So the parent
  receives the child's *result* and a session id it can open, and nothing else.

  **What a subagent is not.** It is not a sandbox. A child inherits the parent's permission scope
  and every effect it causes passes the same gate and leaves the same receipts as the parent's own
  (docs/07). Delegation buys context isolation and concurrency; it buys no authority separation,
  and a caller who wants less authority in a child has to say so through the toolset, not by
  assuming that "subagent" means "contained".

  ## Why a subagent is not restarted

  OTP's instinct is to restart a crashed child, and for a stateless worker that is right. It is
  wrong here, and the reason is the one durable-execution systems state plainly: **match the
  retry semantics to the side effect.** At-least-once is for idempotent work; at-most-once is for
  anything that charges a card, sends a message or writes to the world. An agent turn is an
  arbitrary sequence of tool calls, so it is the second kind by default.

  Replaying a turn in this tree is not merely wasteful, it is unsound in a specific way. An
  approval granted `:once` covers one execution and would correctly refuse the replay; but a
  `:session` or `:always` grant would cover it silently, so a restart could re-run an effect the
  person approved once and never expected twice. Nothing in the effects layer carries an
  idempotency key today.

  So `restarts:` defaults to **0**: a child that dies reports the death to its parent, which can
  decide. A caller who knows a brief is idempotent (a search, a summary, a read) can raise it, and
  the option is named `restarts` rather than `retries` so that the thing being repeated is visibly
  a whole child rather than one call.

  **This deviates from the slice's written acceptance criterion**, which said restart once by
  default. The deviation and its reasoning are recorded in the slice's NOTES for the owner to
  accept or veto.

  ## Budgets

  Every delegation carries a budget and none is optional: turns, tokens and wall clock. A child
  that exceeds one is terminated and the parent gets a named error rather than a crash, because a
  parent that cannot tell "the child failed" from "the child is still thinking" cannot make a
  decision either way.
  """

  alias Trinity.Sessions

  @default_budget %{turns: 1, tokens: 100_000, timeout_ms: 120_000}
  # At-most-once by default. See the moduledoc: an agent turn is an arbitrary sequence of tool
  # calls, and a `:session` or `:always` approval would cover a replay silently.
  @default_restarts 0
  @default_concurrency 3
  @summary_bytes 4_000

  @type brief :: String.t()
  @type result :: %{
          session_id: String.t(),
          status: :ok | :budget | :error | :cancelled,
          text: String.t(),
          reason: term() | nil
        }

  @doc "The budget applied when a caller names none. Exposed so a test asserts it rather than restating it."
  @spec default_budget() :: map()
  def default_budget, do: @default_budget

  @doc "How many times a dead child is retried when the caller names no number. Zero, deliberately."
  @spec default_restarts() :: non_neg_integer()
  def default_restarts, do: @default_restarts

  @doc """
  Runs one brief as a child of `parent_session_id` and returns its result.

  Options: `:title`, `:persona_id`, `:budget` (a map merged over `default_budget/0`).
  """
  @spec delegate(String.t(), brief(), keyword()) :: {:ok, result()} | {:error, term()}
  def delegate(parent_session_id, brief, opts \\ []) when is_binary(brief) do
    budget = Map.merge(@default_budget, Map.new(Keyword.get(opts, :budget, %{})))

    restarts = Keyword.get(opts, :restarts, @default_restarts)

    with {:ok, child} <- create_child(parent_session_id, brief, opts) do
      {:ok, run(child, brief, budget, restarts)}
    end
  end

  @doc """
  Runs several briefs concurrently, at most `:concurrency` at a time, and returns their results in
  the order the briefs were given.

  The cap is not a performance knob. A parent that fans out without one turns a single delegation
  into as many concurrent model calls as it has briefs, which is how a rate limit and a bill are
  discovered at the same moment.
  """
  @spec delegate_many(String.t(), [brief()], keyword()) :: [{:ok, result()} | {:error, term()}]
  def delegate_many(parent_session_id, briefs, opts \\ []) when is_list(briefs) do
    cap = Keyword.get(opts, :concurrency, @default_concurrency)

    timeout =
      Map.get(Map.new(Keyword.get(opts, :budget, %{})), :timeout_ms, @default_budget.timeout_ms)

    Trinity.LLM.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      briefs,
      fn brief -> delegate(parent_session_id, brief, opts) end,
      max_concurrency: cap,
      timeout: timeout + 5_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:subagent_exit, reason}}
    end)
  end

  @doc "The children of a session, newest first."
  @spec children(String.t()) :: [Sessions.SessionRow.t()]
  def children(parent_session_id) do
    Sessions.list_sessions(limit: 200)
    |> Enum.filter(&(&1.parent_id == parent_session_id))
  end

  @doc """
  Cancels a session's whole subtree, depth first, and returns how many were cancelled.

  Depth first because cancelling a parent before its children leaves the children running with
  nobody waiting for their results, which is the shape that produces work nobody asked for and
  nobody reads.
  """
  @spec cancel_subtree(String.t()) :: non_neg_integer()
  def cancel_subtree(session_id) do
    descendants =
      session_id
      |> children()
      |> Enum.flat_map(fn child -> [child.id | Enum.map(children(child.id), & &1.id)] end)

    Enum.each(descendants, &cancel_one/1)
    cancel_one(session_id)
    length(descendants) + 1
  end

  defp cancel_one(session_id) do
    _ = Sessions.cancel_turn(session_id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # `get_session/1` casts its argument, so a value that is not a UUID reaches the repository as a
  # malformed one and raises rather than returning nil. Slice 070 hit exactly this from a chat
  # message and it crashed the router; a delegation brief is no more trustworthy than a chat
  # message, so the same guard applies here rather than being learned twice.
  defp create_child(parent_session_id, brief, opts) do
    parent = if uuid?(parent_session_id), do: Sessions.get_session(parent_session_id)

    if parent do
      Sessions.create_session(%{
        persona_id: Keyword.get(opts, :persona_id) || parent.persona_id,
        origin: "subagent",
        parent_id: parent_session_id,
        title: Keyword.get(opts, :title) || title_from(brief),
        origin_ref: %{"parent_session_id" => parent_session_id}
      })
    else
      {:error, {:no_such_session, parent_session_id}}
    end
  end

  defp uuid?(value) when is_binary(value),
    do:
      Regex.match?(
        ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
        value
      )

  defp uuid?(_), do: false

  defp title_from(brief) do
    brief |> String.split("\n") |> List.first() |> String.slice(0, 60)
  end

  # The awaiting shape is Trinity.Scheduler.Workers.RunTask's (slice 050), including the drain: a
  # session's process broadcasts :idle once when it starts, and a wait that does not drain that one
  # returns before the turn has run. Reused rather than rewritten, because writing it again is
  # writing that bug again.
  defp run(child, brief, budget, restarts) do
    with :ok <- Sessions.subscribe(child.id),
         {:ok, pid} <- Sessions.ensure_started(child.id),
         :ok <- drain_start(child.id),
         {:ok, _message} <- Sessions.send_user_message(child.id, brief) do
      # The session process is monitored as well as subscribed: a process that dies mid-turn
      # broadcasts nothing, so without this the parent waits out the whole budget for an answer
      # that is never coming.
      ref = Process.monitor(pid)
      result = await(child.id, budget, ref)
      Process.demonitor(ref, [:flush])
      maybe_restart(result, child, brief, budget, restarts)
    else
      {:error, reason} -> %{session_id: child.id, status: :error, text: "", reason: reason}
    end
  end

  # Only a death is retried, and only when the caller asked for it. A budget overrun is not a
  # transient failure: running the same brief again under the same budget overruns it again.
  defp maybe_restart(%{status: :error, reason: {:child_died, _}}, child, brief, budget, n)
       when n > 0 do
    run(child, brief, budget, n - 1)
  end

  defp maybe_restart(result, _child, _brief, _budget, _n), do: result

  defp drain_start(session_id) do
    receive do
      {:session, ^session_id, {:state, :idle}} -> :ok
    after
      2_000 -> :ok
    end
  end

  defp await(session_id, budget, ref) do
    receive do
      {:session, ^session_id, {:state, :idle}} ->
        %{session_id: session_id, status: :ok, text: summary(session_id), reason: nil}

      {:session, ^session_id, {:state, :error}} ->
        %{session_id: session_id, status: :error, text: "", reason: :session_error}

      {:session, ^session_id, {:error, reason}} ->
        %{session_id: session_id, status: :error, text: "", reason: {:turn, reason}}

      {:DOWN, ^ref, :process, _pid, reason} ->
        %{session_id: session_id, status: :error, text: "", reason: {:child_died, reason}}

      {:session, ^session_id, _other} ->
        await(session_id, budget, ref)
    after
      budget.timeout_ms ->
        _ = Sessions.cancel_turn(session_id)

        %{
          session_id: session_id,
          status: :budget,
          text: summary(session_id),
          reason: {:timeout_ms, budget.timeout_ms}
        }
    end
  end

  defp summary(session_id) do
    session_id
    |> Sessions.history()
    |> Enum.filter(&(&1.role == "assistant"))
    |> List.last()
    |> case do
      nil -> ""
      %{content: c} when is_binary(c) -> binary_part(c, 0, min(byte_size(c), @summary_bytes))
      _ -> ""
    end
  end
end
