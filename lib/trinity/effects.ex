# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects do
  @moduledoc """
  The membrane (slice 024, docs/07): the one side-effect boundary every `:artifact` and
  `:catalog` effect crosses. A module, not a process; it holds no state, and the only state
  it consults is the receipt chain.

  `execute/2` takes a `Trinity.Authority.Staged` and, in this order, denies with a receipt on
  the first thing that is wrong: the decision is not `:allow`; the tool's effect class is not
  one the membrane admits, or a `:catalog` tool is not in `Trinity.Tools.Catalog`; the
  fingerprint re-derived from the arguments it holds is not the one the decision bound
  (AC4, the M2 re-verify); an effect receipt already names this call (the idempotency key:
  session and call id); the authority in force refuses. Then it writes the effect's admission
  receipt (kind `effect`, phase `admit`), and only if that signed row is in the chain does
  the authority execute (`Trinity.Authority.Local`: the tool's `execute/2`); a signer that
  cannot sign means the effect is denied and the alarm sounds (AC5). The outcome is a second
  effect receipt (phase `done`) with the result's digest; if that one cannot be written the
  effect has already happened, which the alarm and the missing row both say.
  """
  use Boundary,
    deps: [Trinity, Trinity.Tools, Trinity.Permissions, Trinity.Authority, Trinity.Receipts],
    exports: [Boot, Runner]

  alias Trinity.Authority
  alias Trinity.Authority.Staged
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools.{Catalog, Context, Result}

  @admits [:artifact, :catalog]

  @type outcome :: {:ok, Result.t()} | {:error, term()}

  @doc "The effect classes the membrane admits."
  @spec admits() :: [atom()]
  def admits, do: @admits

  @doc "Runs a staged effect through the membrane; every path leaves a receipt or an alarm."
  @spec execute(Staged.t(), Context.t()) :: outcome()
  def execute(%Staged{} = staged, %Context{} = ctx) do
    authority = Authority.impl()

    with :ok <- check_decision(staged),
         :ok <- check_effect(staged),
         :ok <- check_fingerprint(staged),
         :ok <- check_idempotency(staged),
         {:ok, staged} <- authority.stage(staged, ctx),
         {:ok, :allow, basis} <- authority.decide(staged, staged.decision, ctx),
         {:ok, _admit} <- receipt(staged, "admit", %{"basis" => basis}) do
      result = authority.execute(staged, :allow, ctx)
      done(staged, result)
      result
    else
      {:error, reason} ->
        deny(staged, reason)

      {:ok, :deny, basis} ->
        deny(staged, {:authority_denied, basis})
    end
  end

  defp check_decision(%Staged{decision: :allow}), do: :ok
  defp check_decision(%Staged{decision: d}), do: {:error, {:decision_not_allow, d}}

  defp check_effect(%Staged{effect: :catalog, tool: tool}) do
    if tool in Catalog.names(), do: :ok, else: {:error, {:not_in_catalog, tool}}
  end

  defp check_effect(%Staged{effect: :artifact}), do: :ok
  defp check_effect(%Staged{effect: e}), do: {:error, {:effect_not_admitted, e}}

  # M2: the approval bound a fingerprint over the arguments the gate saw; the membrane
  # re-derives it over the arguments it is about to execute, and a divergence denies.
  defp check_fingerprint(%Staged{} = s) do
    derived = Permissions.fingerprint(s.session_id, s.tool, s.args, s.cwd)

    if derived == s.fingerprint,
      do: :ok,
      else: {:error, {:fingerprint_mismatch, s.fingerprint, derived}}
  end

  # The idempotency key is the session and the call id, and the chain is the record: an
  # admission receipt for this reference means the effect has been run (or is running).
  defp check_idempotency(%Staged{} = s) do
    ref = Staged.subject_ref(s)

    case Receipts.by_subject_ref(ref, kind: "effect") do
      [] -> :ok
      [_ | _] -> {:error, {:duplicate_effect, ref}}
    end
  end

  defp deny(%Staged{} = staged, reason) do
    # A denial's receipt may itself fail when the signer is gone; the reason then names both.
    case receipt(staged, "denied", %{"reason" => inspect(reason)}) do
      {:ok, _} -> {:error, {:denied, reason}}
      {:error, why} -> {:error, {:denied, reason, {:receipt_failed, why}}}
    end
  end

  defp done(%Staged{} = staged, result) do
    outcome =
      case result do
        {:ok, %Result{} = r} ->
          %{"ok" => true, "content_digest" => digest(r.content), "truncated" => r.truncated?}

        {:error, reason} ->
          %{"ok" => false, "error" => inspect(reason)}
      end

    receipt(staged, "done", outcome)
  end

  defp receipt(%Staged{} = s, phase, extra) do
    Authority.impl().receipt("effect", %{
      scope: s.scope,
      subject: %{
        "session_id" => s.session_id,
        "call_id" => s.call_id,
        "tool" => s.tool,
        "effect" => Atom.to_string(s.effect),
        "phase" => phase
      },
      decision: Map.merge(%{"outcome" => phase, "gate" => Atom.to_string(s.decision)}, extra),
      fingerprint: s.fingerprint,
      subject_ref: Staged.subject_ref(s),
      meta: %{"authority" => Authority.selected_name()}
    })
  end

  defp digest(content) when is_binary(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp digest(other), do: digest(inspect(other))
end
