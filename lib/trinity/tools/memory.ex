# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Memory do
  @moduledoc """
  `memory`: the agent's writes to its always-on tiers (slice 030, `Trinity.Memory.AlwaysOn`).
  Actions: `add` (tier, key, body), `replace` (key, body), `remove` (key), `promote` (key, to a
  wider scope), `list`. A write goes to the persona's scope unless `scope` says `session`
  (this session only; AC7). Risk `:write`, effect `:artifact`: through the membrane with
  receipts, and allowed without asking by the default persona's rule
  (`settings["permissions"]["memory"]`, seeded at slice 030), which the decision receipt
  names as its basis (AC6). Every change is logged with `by: "tool"` and the session.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Memory.{AlwaysOn, Budget, Entry}
  alias Trinity.Tools.{Context, Result}

  @impl true
  def name, do: "memory"

  @impl true
  def description,
    do:
      "Keeps what is worth remembering across conversations. add: tier (profile: who the person is; " <>
        "always_on: what to keep in mind), a short stable key, a short body. replace and remove by key. " <>
        "promote moves a session-only entry to the persona (scope persona) or to everyone (scope global). " <>
        "list shows what is kept. Store only what the person would want kept."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["add", "replace", "remove", "promote", "list"]
        },
        "tier" => %{
          "type" => "string",
          "enum" => ["profile", "always_on"],
          "description" => "add only; default always_on"
        },
        "key" => %{"type" => "string", "description" => "short, stable, lowercase"},
        "body" => %{"type" => "string", "description" => "add and replace"},
        "scope" => %{
          "type" => "string",
          "enum" => ["persona", "session", "global"],
          "description" => "add: where it lives (default persona); promote: where it goes"
        }
      },
      "required" => ["action"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :write

  @impl true
  def effect, do: :artifact

  @impl true
  def execute(%{"action" => action} = args, %Context{persona: %{id: _} = persona} = ctx) do
    opts = [by: "tool", session_id: ctx.session_id]

    case run(action, args, persona, ctx, opts) do
      {:ok, text} ->
        {:ok, Result.text(text, %{"action" => action, "budget" => Budget.status(persona.id)})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The Session hands its persona in the context; a call without one has no tiers to write.
  def execute(_args, %Context{}), do: {:error, :no_persona}

  defp run("list", _args, persona, ctx, _opts) do
    case AlwaysOn.entries(persona.id, ctx.session_id) do
      [] ->
        {:ok, "Nothing is kept yet."}

      entries ->
        {:ok,
         Enum.map_join(
           entries,
           "\n",
           &"[#{&1.tier}] [#{short_scope(&1.scope)}] #{&1.key}: #{&1.body}"
         )}
    end
  end

  defp run("add", %{"key" => key, "body" => body} = args, persona, ctx, opts) do
    attrs = %{
      persona_id: persona.id,
      tier: Map.get(args, "tier", "always_on"),
      scope: scope(Map.get(args, "scope", "persona"), persona, ctx),
      key: key,
      body: body,
      source_message_id: nil
    }

    case AlwaysOn.add(attrs, opts) do
      {:ok, e} -> {:ok, "Kept #{e.tier} #{e.key} (#{short_scope(e.scope)})."}
      {:error, :exists} -> {:error, {:exists, key}}
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:invalid, errors(cs)}}
    end
  end

  defp run("replace", %{"key" => key, "body" => body}, persona, ctx, opts) do
    with {:ok, entry} <- find(persona, ctx, key),
         {:ok, e} <- AlwaysOn.replace(entry, body, opts) do
      {:ok, "Replaced #{e.tier} #{e.key}."}
    else
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:invalid, errors(cs)}}
      other -> other
    end
  end

  defp run("remove", %{"key" => key}, persona, ctx, opts) do
    with {:ok, entry} <- find(persona, ctx, key),
         {:ok, e} <- AlwaysOn.remove(entry, opts) do
      {:ok, "Removed #{e.tier} #{e.key}."}
    end
  end

  defp run("promote", %{"key" => key} = args, persona, ctx, opts) do
    to = scope(Map.get(args, "scope", "persona"), persona, ctx)

    with {:ok, entry} <- find(persona, ctx, key),
         {:ok, e} <- AlwaysOn.promote(entry, to, opts) do
      {:ok, "Promoted #{e.tier} #{e.key} to #{short_scope(e.scope)}."}
    else
      {:error, :exists} -> {:error, {:exists, key}}
      other -> other
    end
  end

  defp run(action, _args, _persona, _ctx, _opts), do: {:error, {:missing_arguments, action}}

  # The innermost entry with this key in the session's chain.
  defp find(persona, ctx, key) do
    case Enum.find(AlwaysOn.entries(persona.id, ctx.session_id), &(&1.key == key)) do
      nil -> {:error, {:not_found, key}}
      %Entry{} = e -> {:ok, e}
    end
  end

  defp scope("session", _persona, %Context{session_id: sid}) when is_binary(sid),
    do: AlwaysOn.session_scope(sid)

  defp scope("global", _persona, _ctx), do: "global"
  defp scope(_, persona, _ctx), do: AlwaysOn.persona_scope(persona.id)

  defp short_scope("global"), do: "global"
  defp short_scope("persona:" <> _), do: "persona"
  defp short_scope("session:" <> _), do: "session"
  defp short_scope(other), do: other

  defp errors(cs), do: Ecto.Changeset.traverse_errors(cs, fn {m, _} -> m end)
end
