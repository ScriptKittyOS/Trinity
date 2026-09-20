# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Runner do
  @moduledoc """
  Runs the tool calls of one turn. Slice 020, the implementation behind
  `Trinity.Sessions.ToolRunner`.

  All the turn's calls run at once, each in its own task under `Trinity.Tools.TaskSupervisor`
  with its tool's timeout; the Session waits for the set. One call: look the name up, validate
  the arguments against the schema (refused, never repaired), ask `Trinity.Permissions.decide/3`
  exactly once, run `execute/2`, cap the result. A crash is an error result, a timeout an error
  result, an unknown name an error result: the model reads each, and the session goes on.
  Nothing here writes a row; the Session records what comes back, with the tool's definition
  digest beside it.

  The contract is `Trinity.Sessions.ToolRunner`'s (`run/2`, `run_all/2`), which the Session
  calls and which names this module as its default implementation. It is not declared with
  `@behaviour` here: Sessions depends on Tools (the declared surface), so a reference the
  other way would be a cycle `boundary` refuses; `Trinity.Tools.RunnerTest` asserts the two
  functions exist with the seam's arities instead.
  """

  alias Trinity.Permissions
  alias Trinity.Tools.{Context, Registry, Result, Schema}

  @default_timeout 30_000
  @grace 100

  @doc "The configured default timeout in milliseconds (`config :trinity, :tools, timeout_ms`)."
  @spec default_timeout() :: pos_integer()
  def default_timeout do
    Application.get_env(:trinity, :tools, []) |> Keyword.get(:timeout_ms, @default_timeout)
  end

  @doc "One call (the seam's `run/2`)."
  @spec run(map(), map()) :: {:ok, Result.t(), map()} | {:error, term(), map()}
  def run(call, context) do
    [{_call, outcome}] = run_all([call], context)
    outcome
  end

  @doc "Every call of a turn, at once, answered in the order given (the seam's `run_all/2`)."
  @spec run_all([map()], map()) :: [{map(), {:ok, Result.t(), map()} | {:error, term(), map()}}]
  def run_all(calls, context) when is_list(calls) do
    ctx = to_context(context)
    longest = calls |> Enum.map(&timeout_of/1) |> Enum.max(fn -> default_timeout() end)

    Trinity.Tools.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(calls, &{&1, run_one(&1, ctx)},
      max_concurrency: max(length(calls), 1),
      timeout: longest + @grace,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(calls)
    |> Enum.map(fn
      {{:ok, {call, outcome}}, _} -> {call, outcome}
      {{:exit, reason}, call} -> {call, {:error, {:crash, reason}, meta(call.name)}}
    end)
  end

  # One call, with its own timeout inside the task so a slow tool is a timeout error for that
  # call rather than a killed task for the set.
  defp run_one(call, ctx) do
    task = Task.async(fn -> execute(call, ctx) end)

    case Task.yield(task, timeout_of(call)) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:error, {:crash, reason}, meta(call.name)}
      nil -> {:error, :timeout, meta(call.name)}
    end
  end

  defp execute(%{name: name, args: args}, ctx) do
    with {:ok, entry} <- Registry.lookup(name),
         {:ok, args} <- validate(entry, args),
         :allow <-
           Permissions.decide(ctx.session_id, name, args,
             persona: ctx.persona,
             cwd: ctx.cwd,
             escalate: escalation(entry, args, ctx)
           ),
         {:ok, %Result{} = result} <- call_tool(entry, args, ctx) do
      {:ok, Result.cap(result), meta(name)}
    else
      {:error, reason} -> {:error, reason, meta(name)}
      :deny -> {:error, :denied, meta(name)}
      :ask -> {:error, ask(ctx, name, args), meta(name)}
      other -> {:error, {:bad_return, other}, meta(name)}
    end
  end

  # An :ask with a session to ask becomes a pending approval (a row, then a broadcast) the
  # Session waits on; without a session there is nobody to ask, and the call is refused.
  defp ask(%Context{session_id: nil}, _name, _args), do: :approval_required

  defp ask(%Context{session_id: sid, cwd: cwd} = ctx, name, args) do
    risk =
      case Registry.lookup(name) do
        {:ok, entry} -> Permissions.effective_tier(name, escalation(entry, args, ctx))
        _ -> :ask
      end

    case Permissions.request_approval(sid, name, args, cwd: cwd, risk: risk) do
      {:ok, approval} -> {:approval_required, approval.id}
      {:error, reason} -> {:request_failed, reason}
    end
  end

  # The tool's own reading of its arguments (slice 022): a tier it raises the call to, or nil.
  defp escalation(%{module: module}, args, ctx) do
    if function_exported?(module, :escalate, 2), do: module.escalate(args, ctx), else: nil
  end

  defp validate(%{module: module}, args) do
    case Schema.validate(module.schema(), args) do
      {:ok, args} -> {:ok, args}
      {:error, reasons} -> {:error, {:invalid_args, reasons}}
    end
  end

  defp call_tool(%{module: module}, args, ctx) do
    module.execute(args, ctx)
  rescue
    e -> {:error, {:crash, {e, __STACKTRACE__}}}
  end

  defp timeout_of(%{name: name}) do
    with {:ok, %{module: m}} <- Registry.lookup(name),
         true <- function_exported?(m, :timeout, 0) do
      m.timeout()
    else
      _ -> default_timeout()
    end
  end

  defp meta(name) when is_binary(name) do
    case Registry.lookup(name) do
      {:ok, %{digest: digest}} -> %{"tool" => name, "tool_definition_digest" => digest}
      _ -> %{"tool" => name, "tool_definition_digest" => nil}
    end
  end

  defp to_context(%Context{} = ctx), do: ctx
  defp to_context(map) when is_map(map), do: struct(Context, map)
end
