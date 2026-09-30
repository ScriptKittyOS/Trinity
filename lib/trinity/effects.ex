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
  (AC4, the M2 re-verify); `stage/2` gave back an effect that is not the one it was handed;
  an effect receipt already names this call (the idempotency key: session and call id); the
  authority in force refuses. Then it writes the effect's admission receipt (kind `effect`,
  phase `admit`), and only if that signed row is in the chain does the tool run; a signer that
  cannot sign means the effect is denied and the alarm sounds (AC5). The outcome is a second
  effect receipt (phase `done`) with the result's digest; if that one cannot be written the
  effect has already happened, which the alarm and the missing row both say.

  ## Where the effect happens (owner ruling, 2026-09-30)

  **The model proposes, the authority in force decides, and the tool runs here.** After a
  `decide/3` allow and after the admission receipt is in the chain, this module calls the tool's
  own `execute/2`, in this VM. It does not call `authority.execute/3`, and no adapter runs a
  tool: an adapter that could would be a second executor living in another repository, outside
  every check this function makes.

  The fingerprint is verified twice, and the second time is the point. The first is over the
  arguments the membrane holds, against the one the gate bound. The second is after `stage/2`
  has handed the effect to the authority and handed something back, because until then a
  returned `Staged` was used unexamined and could carry different arguments, or the same
  arguments and a different `module`, which the fingerprint does not cover. An authority may set
  `staged_at` and `basis` and nothing else.
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
         {:ok, restaged} <- authority.stage(staged, ctx),
         :ok <- check_stage_kept_the_subject(staged, restaged),
         {:ok, :allow, basis} <- authority.decide(restaged, restaged.decision, ctx),
         {:ok, _admit} <- receipt(restaged, "admit", %{"basis" => basis}) do
      result = run_tool(restaged, ctx)
      done(restaged, result)
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

  # Owner ruling 2026-09-30. `stage/2` hands the effect to the authority in force and gets a
  # `Staged` back, and until this check the returned one was used unexamined. An adapter could
  # therefore change what runs after the fingerprint had already been verified: swap `args`,
  # or keep the arguments and swap `module`, which the fingerprint does not cover at all.
  #
  # The subject of the decision is fixed before `stage/2` and may not move. The authority may
  # set exactly two fields, `staged_at` and `basis`, which say when it saw the effect and why it
  # decided as it did; every other field must come back as it went in, and the fingerprint is
  # re-derived over the returned arguments and compared to the one the gate bound, not to
  # whatever the returned struct now carries. An adapter that rewrote both `args` and
  # `fingerprint` to agree with each other would pass a check that compared them to each other.
  defp check_stage_kept_the_subject(%Staged{} = before, %Staged{} = restaged) do
    # The fingerprint is checked first so that the ordinary case, an authority that changed the
    # arguments, is reported as a fingerprint mismatch rather than as a changed field. The field
    # check then catches what a fingerprint cannot see, `module` above all.
    case check_fingerprint_against(before.fingerprint, restaged) do
      :ok -> check_subject_fields(before, restaged)
      {:error, _} = error -> error
    end
  end

  defp check_stage_kept_the_subject(_before, other),
    do: {:error, {:stage_returned_not_staged, other}}

  defp check_subject_fields(before, restaged) do
    pinned = %{before | staged_at: nil, basis: %{}}
    returned = %{restaged | staged_at: nil, basis: %{}}

    if pinned == returned,
      do: :ok,
      else: {:error, {:stage_changed_the_subject, changed_fields(pinned, returned)}}
  end

  defp changed_fields(pinned, returned) do
    pinned
    |> Map.from_struct()
    |> Enum.filter(fn {k, v} -> Map.get(Map.from_struct(returned), k) != v end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.sort()
  end

  defp check_fingerprint_against(bound, %Staged{} = s) do
    derived = Permissions.fingerprint(s.session_id, s.tool, s.args, s.cwd)

    if derived == bound,
      do: :ok,
      else: {:error, {:fingerprint_mismatch_after_stage, bound, derived}}
  end

  # Owner ruling 2026-09-30: the model proposes, the authority in force decides, and the tool
  # runs **here**, in this VM, after a `decide/3` allow and after the admission receipt is in the
  # chain. This is the one call of a tool's `execute/2` on the effect path; the census test in
  # test/trinity/effects/census_test.exs holds that.
  #
  # It does not go through `authority.execute/3`, and no adapter runs the tool. An adapter that
  # could run it would be a second executor, in another repository, outside the membrane that
  # every other check in this function belongs to.
  defp run_tool(%Staged{module: module, args: args}, ctx) do
    module.execute(args, ctx)
  rescue
    e -> {:error, {:crash, {e, __STACKTRACE__}}}
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
