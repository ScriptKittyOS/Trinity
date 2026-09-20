# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects.Runner do
  @moduledoc """
  The tool runner in force from slice 024 (`config :trinity, :tool_runner`), behind the
  `Trinity.Sessions.ToolRunner` seam. `Trinity.Tools.Runner` does the lookup, validation,
  timeouts and concurrency; this module supplies the executor: the gate's decision, asked
  once and receipted every time (kind `decision`); then for an `effect: :none` tool the call
  runs directly with a query receipt, and for anything else the staged effect goes through
  `Trinity.Effects.execute/2`, the membrane.

  Nothing fails open: a decision that cannot be receipted (no signer) refuses the call,
  reads included, and the alarm says why.
  """

  alias Trinity.Authority.Staged
  alias Trinity.Receipts
  alias Trinity.Tools.{Context, Result, Runner}

  @doc "One call (the seam's `run/2`)."
  @spec run(map(), map()) :: {:ok, Result.t(), map()} | {:error, term(), map()}
  def run(call, context) do
    [{_call, outcome}] = run_all([call], context)
    outcome
  end

  @doc "Every call of a turn (the seam's `run_all/2`), through the membrane's executor."
  @spec run_all([map()], map()) :: [{map(), {:ok, Result.t(), map()} | {:error, term(), map()}}]
  def run_all(calls, context) when is_list(calls), do: Runner.run_all(calls, context, &execute/3)

  @doc "The executor: decide and receipt, then read directly or cross the membrane."
  @spec execute(map(), map(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def execute(entry, args, %Context{} = ctx) do
    {decision, fp, reason} =
      case Runner.decide(entry, args, ctx) do
        {:allow, fp} -> {:allow, fp, nil}
        {:deny, fp} -> {:deny, fp, :denied}
        {:ask, why, fp} -> {:ask, fp, why}
      end

    scope = scope(ctx)

    case decision_receipt(scope, entry, ctx, decision, fp, reason) do
      {:ok, _} -> dispatch(decision, entry, args, ctx, scope, fp, reason)
      {:error, why} -> {:error, {:decision_not_receipted, why}}
    end
  end

  defp dispatch(:allow, %{effect: :none} = entry, args, ctx, scope, _fp, _reason) do
    result = Runner.call_tool(entry, args, ctx)
    query_receipt(scope, entry, ctx, result)
    result
  end

  defp dispatch(:allow, %{name: name, effect: effect} = entry, args, ctx, scope, fp, _reason) do
    Trinity.Effects.execute(
      %Staged{
        tool: name,
        module: entry.module,
        effect: effect,
        args: args,
        call_id: ctx.call_id,
        session_id: ctx.session_id,
        scope: scope,
        cwd: ctx.cwd,
        decision: :allow,
        fingerprint: fp
      },
      ctx
    )
  end

  defp dispatch(_decision, _entry, _args, _ctx, _scope, _fp, reason), do: {:error, reason}

  @doc "The chain scope a context's receipts go to."
  @spec scope(Context.t()) :: String.t()
  def scope(%Context{session_id: nil}), do: Receipts.session_scope("none")
  def scope(%Context{session_id: sid}), do: Receipts.session_scope(sid)

  defp decision_receipt(
         scope,
         %{name: name, effect: effect, digest: digest},
         ctx,
         decision,
         fp,
         reason
       ) do
    Receipts.append(scope, %{
      kind: "decision",
      subject: %{
        "session_id" => ctx.session_id,
        "call_id" => ctx.call_id,
        "tool" => name,
        "effect" => Atom.to_string(effect)
      },
      decision: %{"outcome" => Atom.to_string(decision), "reason" => reason && inspect(reason)},
      fingerprint: fp,
      subject_ref: "decision:#{ctx.session_id || "none"}:#{ctx.call_id || "none"}",
      meta: %{"tool_definition_digest" => digest}
    })
  end

  # Every read emits a query receipt (docs/07): chained, checkpointed, never blocking the read.
  defp query_receipt(scope, %{name: name, digest: digest}, ctx, result) do
    outcome =
      case result do
        {:ok, %Result{}} -> %{"ok" => true}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end

    Receipts.append(scope, %{
      kind: "query",
      subject: %{"session_id" => ctx.session_id, "call_id" => ctx.call_id, "tool" => name},
      decision: outcome,
      subject_ref: "query:#{ctx.session_id || "none"}:#{ctx.call_id || "none"}",
      meta: %{"tool_definition_digest" => digest}
    })
  end
end
