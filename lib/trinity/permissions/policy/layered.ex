# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Policy.Layered do
  @moduledoc """
  The layered policy docs/07 specifies, in its order. Slice 021.

  1. Session grants: `tool_permissions` rows scoped `session:<id>` whose fingerprint pattern
     is this call's fingerprint and whose expiry has not passed ("allow for this session").
  2. The newest decided approval for this fingerprint in this session, if not yet consumed:
     "allow once" allows and is consumed by the call; a denial denies and is consumed too, so
     the same call asks again next time rather than staying refused.
  3. The persona's policy: `settings["permissions"]`, tool name to decision.
  4. Global rules: `tool_permissions` rows scoped `global`, an argument glob each.
  5. The default by tier (`config :trinity, :permissions, default:`), `:ask` for an unmapped
     name; the tier is the name's raised by the tool's escalation when that is higher.

  The fingerprint is re-derived here from the arguments actually passed (M2): a grant bound
  to other arguments does not match, and the call asks again.
  """
  @behaviour Trinity.Permissions.Policy

  alias Trinity.Permissions
  alias Trinity.Permissions.{Rule, Store}

  @default %{read: :allow, network: :allow, write: :ask, exec: :ask, destructive: :ask}

  @impl true
  def decide(session_id, tool, args, opts) do
    now = DateTime.utc_now()
    fp = Permissions.fingerprint(session_id, tool, args, Keyword.get(opts, :cwd))

    with :next <- session_grants(session_id, tool, args, fp, now),
         :next <- decided_approval(session_id, fp, now),
         :next <- persona(Keyword.get(opts, :persona), tool),
         :next <- global_rules(tool, args, fp, now) do
      default(tool, Keyword.get(opts, :escalate))
    end
  end

  defp session_grants(nil, _tool, _args, _fp, _now), do: :next

  defp session_grants(session_id, tool, args, fp, now) do
    tool
    |> Store.rules([Permissions.scope(session_id)], now)
    |> first_match(args, fp)
  end

  defp decided_approval(nil, _fp, _now), do: :next

  defp decided_approval(session_id, fp, now) do
    case Store.decided_for(session_id, fp) do
      [%{consumed_at: nil, status: "allowed", decision: "once"} = a | _] ->
        if Store.consume_once(a, now), do: :allow, else: :next

      [%{consumed_at: nil, status: "denied"} = a | _] ->
        if Store.consume_once(a, now), do: :deny, else: :next

      _ ->
        :next
    end
  end

  defp persona(%{settings: %{"permissions" => perms}}, tool) when is_map(perms) do
    case Map.get(perms, tool) do
      "allow" -> :allow
      "deny" -> :deny
      "ask" -> :ask
      _ -> :next
    end
  end

  defp persona(_, _), do: :next

  defp global_rules(tool, args, fp, now) do
    tool |> Store.rules(["global"], now) |> first_match(args, fp)
  end

  defp first_match(rules, args, fp) do
    case Enum.find(rules, &Rule.matches?(&1.pattern, args, fp)) do
      nil -> :next
      %{decision: d} -> String.to_existing_atom(d)
    end
  end

  # The default by tier, the name's raised by the tool's escalation (slice 022): a read outside
  # the roots and a dangerous command reach here as `:ask` and `:destructive`, never lower.
  defp default(tool, escalation) do
    defaults =
      Application.get_env(:trinity, :permissions, [])
      |> Keyword.get(:default, @default)

    case Permissions.effective_tier(tool, escalation) do
      :ask -> :ask
      tier -> Map.get(defaults, tier, :ask)
    end
  end
end
