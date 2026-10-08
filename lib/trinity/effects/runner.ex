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
  alias Trinity.Tools.FS.Guard

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
    # Slice 135: the guard's verdicts are taken once, decide on them, and are receipted as taken.
    verdicts = Runner.fs_verdicts(entry, args, ctx)

    {decision, fp, reason, basis} =
      case Runner.decide(entry, args, ctx, verdicts) do
        {:allow, fp, basis} -> {:allow, fp, nil, basis}
        {:deny, fp, "fs_guard"} -> {:deny, fp, fs_denied(verdicts), "fs_guard"}
        {:deny, fp, basis} -> {:deny, fp, :denied, basis}
        {:ask, why, fp, basis} -> {:ask, fp, why, basis}
      end

    scope = scope(ctx)
    fs = Enum.map(verdicts, &Guard.receipt_fields(&1, entry.name, ctx))

    case decision_receipt(scope, entry, ctx, {decision, fp, reason, basis}, fs) do
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

  # The model is told which path was refused and by which rule, never anything read.
  defp fs_denied(verdicts), do: {:fs_denied, Enum.find(verdicts, &(&1.decision == :deny))}

  defp decision_receipt(
         scope,
         %{name: name, effect: effect, digest: digest},
         ctx,
         {decision, fp, reason, basis},
         fs
       ) do
    Receipts.append(scope, %{
      kind: "decision",
      subject:
        origin(ctx, %{
          "session_id" => ctx.session_id,
          "call_id" => ctx.call_id,
          "tool" => name,
          "effect" => Atom.to_string(effect)
        }),
      decision:
        with_fs(
          %{
            "outcome" => Atom.to_string(decision),
            "basis" => basis,
            "reason" => reason && inspect(reason)
          },
          fs
        ),
      fingerprint: fp,
      subject_ref: "decision:#{ctx.session_id || "none"}:#{ctx.call_id || "none"}",
      meta: trace(ctx, %{"tool_definition_digest" => digest})
    })
  end

  # Slice 135, AC6: every fs decision is on the chain, a decision receipt's denials included. A
  # call that names no host path carries no `fs` key, so every other receipt reads as before.
  defp with_fs(decision, []), do: decision
  defp with_fs(decision, fs), do: Map.put(decision, "fs", fs)

  # Every read emits a query receipt (docs/07): chained, checkpointed, never blocking the read.
  # Slice 135: a refusal the guard made at open (a swap since the decision, a file met inside a
  # directory a grep walked) rides on it with the same fields as the decision's.
  defp query_receipt(scope, %{name: name, digest: digest}, ctx, result) do
    outcome =
      case result do
        {:ok, %Result{}} -> %{"ok" => true}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end

    fs = Enum.map(open_refusals(result), &Guard.receipt_fields(&1, name, ctx))
    outcome = with_fs(outcome, fs)

    Receipts.append(scope, %{
      kind: "query",
      subject:
        origin(ctx, %{"session_id" => ctx.session_id, "call_id" => ctx.call_id, "tool" => name}),
      decision: outcome,
      subject_ref: "query:#{ctx.session_id || "none"}:#{ctx.call_id || "none"}",
      meta: trace(ctx, %{"tool_definition_digest" => digest})
    })
  end

  defp open_refusals({:error, {:fs_denied, %{} = verdict}}), do: [verdict]

  defp open_refusals({:ok, %Result{meta: %{"fs_refused" => refused}}}) when is_list(refused),
    do: refused

  defp open_refusals(_), do: []

  # Slice 061: a call that did not come from the desktop says where it came from (`"mcp"`),
  # and the caller's trace context rides in the meta for 090; a desktop call carries neither,
  # so every receipt written before this slice reads the same.
  defp origin(%Context{origin: nil}, subject), do: subject

  defp origin(%Context{origin: origin} = ctx, subject),
    do: subject |> Map.put("origin", origin) |> principal(ctx)

  # Slice 062: an MCP caller's issuer, subject and scope on every receipt its call leaves
  # (the context carries the receipt form, string keys, never a token).
  defp principal(subject, %Context{principal: %{} = p}) when map_size(p) > 0,
    do: Map.put(subject, "principal", p)

  defp principal(subject, _ctx), do: subject

  defp trace(%Context{trace: %{} = trace}, meta) when map_size(trace) > 0,
    do: Map.put(meta, "trace", trace)

  defp trace(_ctx, meta), do: meta
end
