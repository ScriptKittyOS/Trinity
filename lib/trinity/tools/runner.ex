# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Runner do
  @moduledoc """
  Runs the tool calls of one turn. Slice 020, the implementation behind
  `Trinity.Sessions.ToolRunner`.

  All the turn's calls run at once, each in its own task under `Trinity.Tools.TaskSupervisor`
  with its tool's timeout; the Session waits for the set. One call: look the name up, validate
  the arguments against the schema (refused, never repaired), hand the entry and the
  arguments to the executor, cap the result. A crash is an error result, a timeout an error
  result, an unknown name an error result: the model reads each, and the session goes on.
  Nothing here writes a row; the Session records what comes back, with the tool's definition
  digest beside it.

  Slice 024: the executor is a function argument (`run_all/3`), because the membrane lives
  in `Trinity.Effects`, which depends on this boundary, and a reference the other way would
  be a cycle `boundary` refuses. `Trinity.Effects.Runner` is the seam's implementation in
  force and passes its executor in; the default executor here, `execute_direct/3`, decides
  through the gate and runs `execute/2` for `effect: :none` tools only, refusing an
  effectful tool by name (the census in test/trinity/effects/census_test.exs holds that this
  guard and `Trinity.Authority.Local` are the only two callers of `execute/2`).

  The contract is `Trinity.Sessions.ToolRunner`'s (`run/2`, `run_all/2`). It is not declared
  with `@behaviour` here for the reason above; `Trinity.Tools.RunnerTest` asserts the two
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

  @type executor :: (Registry.entry(), map(), Context.t() -> {:ok, Result.t()} | {:error, term()})

  @doc "One call (the seam's `run/2`), with the default executor."
  @spec run(map(), map()) :: {:ok, Result.t(), map()} | {:error, term(), map()}
  def run(call, context) do
    [{_call, outcome}] = run_all([call], context)
    outcome
  end

  @doc "Every call of a turn, at once, answered in the order given (the seam's `run_all/2`), with the default executor."
  @spec run_all([map()], map()) :: [{map(), {:ok, Result.t(), map()} | {:error, term(), map()}}]
  def run_all(calls, context) when is_list(calls), do: run_all(calls, context, &execute_direct/3)

  @doc "The same, with the executor that runs a validated call (slice 024: the membrane's runner passes its own)."
  @spec run_all([map()], map(), executor()) :: [
          {map(), {:ok, Result.t(), map()} | {:error, term(), map()}}
        ]
  def run_all(calls, context, executor) when is_list(calls) and is_function(executor, 3) do
    ctx = to_context(context)
    longest = calls |> Enum.map(&timeout_of/1) |> Enum.max(fn -> default_timeout() end)

    Trinity.Tools.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(calls, &{&1, run_one(&1, ctx, executor)},
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
  defp run_one(call, ctx, executor) do
    task = Task.async(fn -> execute(call, ctx, executor) end)

    case Task.yield(task, timeout_of(call)) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:error, {:crash, reason}, meta(call.name)}
      nil -> {:error, :timeout, meta(call.name)}
    end
  end

  defp execute(%{name: name, args: args} = call, ctx, executor) do
    ctx = %{ctx | call_id: Map.get(call, :id), tool: name}

    with {:ok, entry} <- Registry.lookup(name),
         {:ok, args} <- validate(entry, args),
         {:ok, %Result{} = result} <- executor.(entry, args, ctx) do
      {:ok, Result.cap(result), meta(name)}
    else
      {:error, reason} -> {:error, reason, meta(name)}
      other -> {:error, {:bad_return, other}, meta(name)}
    end
  end

  @doc """
  The default executor: the gate's decision, then `execute/2` for an `effect: :none` tool.
  An effectful tool is refused here by name; only the membrane runs those.
  """
  @spec execute_direct(Registry.entry(), map(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def execute_direct(entry, args, ctx) do
    case decide(entry, args, ctx) do
      {:allow, _fp, _basis} -> call_tool(entry, args, ctx)
      {:deny, _fp, _basis} -> {:error, :denied}
      {:ask, reason, _fp, _basis} -> {:error, reason}
    end
  end

  @doc """
  The gate's decision for a validated call, asked exactly once, with the fingerprint the
  decision bound and the layer that decided (slice 030): `{:allow, fp, basis}`,
  `{:deny, fp, basis}`, or `{:ask, reason, fp, basis}` where the reason is
  `{:approval_required, id}` (a pending approval the Session waits on), `:approval_required`
  (no session to ask) or `{:request_failed, why}`.
  """
  @spec decide(Registry.entry(), map(), Context.t()) ::
          {:allow, String.t(), String.t()}
          | {:deny, String.t(), String.t()}
          | {:ask, term(), String.t(), String.t()}
  def decide(%{name: name} = entry, args, ctx) do
    fp = Permissions.fingerprint(ctx.session_id, name, args, ctx.cwd)

    case Permissions.decide_with_basis(ctx.session_id, name, args,
           persona: ctx.persona,
           cwd: ctx.cwd,
           escalate: escalation(entry, args, ctx)
         ) do
      {:allow, basis} -> {:allow, fp, basis}
      {:deny, basis} -> {:deny, fp, basis}
      {:ask, basis} -> {:ask, ask(ctx, entry, args), fp, basis}
    end
  end

  # An :ask with a session to ask becomes a pending approval (a row, then a broadcast) the
  # Session waits on; without a session there is nobody to ask, and the call is refused.
  defp ask(%Context{session_id: nil}, _entry, _args), do: :approval_required

  defp ask(%Context{session_id: sid, cwd: cwd} = ctx, %{name: name} = entry, args) do
    risk = Permissions.effective_tier(name, escalation(entry, args, ctx))

    case Permissions.request_approval(sid, name, args, cwd: cwd, risk: risk) do
      {:ok, approval} -> {:approval_required, approval.id}
      {:error, reason} -> {:request_failed, reason}
    end
  end

  @doc "The tool's own reading of its arguments (slice 022): a tier it raises the call to, or nil."
  @spec escalation(Registry.entry(), map(), Context.t()) :: Permissions.tier() | nil
  def escalation(%{module: module}, args, ctx) do
    if function_exported?(module, :escalate, 2), do: module.escalate(args, ctx), else: nil
  end

  defp validate(entry, args) do
    case Schema.validate(Registry.schema(entry), args) do
      {:ok, args} -> {:ok, args}
      {:error, reasons} -> {:error, {:invalid_args, reasons}}
    end
  end

  @doc """
  Runs a validated, allowed `effect: :none` call directly. An effectful entry is refused by
  name: this is one of the two callers of `execute/2` the census allows, and the guard is
  what keeps it a caller for reads only.
  """
  @spec call_tool(Registry.entry(), map(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def call_tool(%{effect: :none, module: module}, args, ctx) do
    module.execute(args, ctx)
  rescue
    e -> {:error, {:crash, {e, __STACKTRACE__}}}
  end

  def call_tool(%{name: name}, _args, _ctx),
    do: {:error, {:effectful_tool_outside_membrane, name}}

  defp timeout_of(%{name: name}) do
    with {:ok, entry} <- Registry.lookup(name),
         t when is_integer(t) <- Registry.timeout(entry) do
      t
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
