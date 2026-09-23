# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Commands do
  @moduledoc """
  What a channel can ask for without talking to the model (slice 070): a registry of slash
  commands, so a platform adapter adds none of its own and a new command is a clause here rather
  than a change to the router.

  Every command answers with text the router sends back. A command never decides an approval by
  itself: `/approve` and `/deny` go through
  `Trinity.Permissions`, after `Trinity.Gateways.Cap` has said whether a channel of this kind may
  answer a request of that tier at all (docs/07, the channel trust cap).
  """

  alias Trinity.Gateways.{Adapter, Cap, Format, Receipts, Router}
  alias Trinity.Permissions
  alias Trinity.Sessions

  @doc "The commands, with one line of help each."
  @spec help() :: [{String.t(), String.t()}]
  def help do
    [
      {"/new", "start a fresh session for this conversation"},
      {"/sessions", "list the most recent sessions"},
      {"/attach <id>", "watch an existing session from here"},
      {"/approve <id>", "approve a pending request, up to this channel's tier"},
      {"/deny <id>", "deny a pending request"},
      {"/help", "this list"}
    ]
  end

  @doc "Runs a command for an inbound message: the text for the channel, and the router's state."
  @spec handle(map(), map()) :: {String.t(), map()}
  def handle(%{text: text} = message, state) do
    {command, argument} = split(text)
    run(command, argument, message, state)
  end

  defp split(text) do
    case text |> String.trim() |> String.split(" ", parts: 2) do
      [command] -> {command, ""}
      [command, rest] -> {command, String.trim(rest)}
    end
  end

  defp run("/help", _argument, _message, state) do
    body = Enum.map_join(help(), "\n", fn {name, line} -> "#{name} — #{line}" end)
    {"What I answer here:\n" <> body, state}
  end

  defp run("/new", _argument, message, state) do
    {"Started a new session.", forget(state, message)}
  end

  defp run("/sessions", _argument, _message, state) do
    case Sessions.list_sessions(limit: 5) do
      [] ->
        {"No sessions yet.", state}

      sessions ->
        body =
          Enum.map_join(sessions, "\n", fn session ->
            "#{String.slice(session.id, 0, 8)} — #{session.title || "(untitled)"} (#{session.origin})"
          end)

        {"Recent sessions:\n" <> body, state}
    end
  end

  defp run("/attach", "", _message, state), do: {"Say /attach <session id>.", state}

  defp run("/attach", argument, message, state) do
    case resolve_session(argument) do
      nil ->
        {"No session starts with #{argument}.", state}

      session ->
        state = Router.bind_state(state, message.adapter, message.conversation, session.id)

        {"Attached to #{String.slice(session.id, 0, 8)}. Both surfaces see this session now.",
         state}
    end
  end

  defp run(decision, argument, message, state) when decision in ["/approve", "/deny"] do
    {decide(decision, argument, message), state}
  end

  defp run(unknown, _argument, _message, state),
    do: {"I do not know #{unknown}. Say /help for the list.", state}

  # An approval answered from a channel: the request is found by the short form the person was
  # shown, the cap decides whether a channel of this kind may answer a request of that tier at
  # all, and only then does `Permissions.decide_request/3` make the decision. The cap is applied
  # after the gate's own decision and never instead of it (docs/07); a capped answer is refused
  # in words and receipted, because a silent refusal teaches a person the bot is broken.
  defp decide(_command, "", _message), do: "Say /approve <id> or /deny <id>."

  defp decide(command, argument, message) do
    case find_pending(argument) do
      nil ->
        "No pending approval starts with #{argument}."

      approval ->
        answer(command, approval, message)
    end
  end

  defp answer(command, approval, message) do
    if Cap.allows?(message.adapter, approval.risk) do
      decided(command, approval, message)
    else
      Receipts.gateway_cap_refusal(approval, message)
      Cap.refusal(message.adapter, approval.risk)
    end
  end

  defp decided("/approve", approval, message) do
    case Permissions.decide_request(approval.id, :once, by: decider(message)) do
      {:ok, _} -> "Approved #{Format.short(approval.id)}."
      {:error, reason} -> "Not decided: #{inspect(reason)}."
    end
  end

  defp decided("/deny", approval, message) do
    case Permissions.decide_request(approval.id, :deny, by: decider(message)) do
      {:ok, _} -> "Denied #{Format.short(approval.id)}."
      {:error, reason} -> "Not decided: #{inspect(reason)}."
    end
  end

  # Who decided, as the approval row records it: the channel and the account, never "liveview".
  defp decider(message),
    do: "gateway:" <> Adapter.name(message.adapter) <> ":" <> message.external_user_id

  defp find_pending(argument) do
    Enum.find(Permissions.pending(:all), &String.starts_with?(&1.id, argument))
  end

  # `/new` forgets the binding; the next message creates a session as a first message does.
  defp forget(state, message) do
    conv_key = {Adapter.name(message.adapter), message.conversation}

    case get_in(state.conversations, [conv_key, :session_id]) do
      nil ->
        state

      session_id ->
        state
        |> update_in([:conversations], &Map.delete(&1, conv_key))
        |> update_in([:sessions], &Map.delete(&1, session_id))
    end
  end

  # A person types the short form they were shown, so a prefix resolves when it is unambiguous.
  # The full id is only looked up when it is one: `get_session/1` casts, and a prefix reaches the
  # repo as a malformed UUID and raises, which is a message from a channel crashing the router.
  defp resolve_session(argument) do
    if uuid?(argument),
      do: Sessions.get_session(argument) || by_prefix(argument),
      else: by_prefix(argument)
  end

  defp uuid?(argument),
    do:
      Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, argument)

  defp by_prefix(prefix) do
    case Enum.filter(Sessions.list_sessions(limit: 50), &String.starts_with?(&1.id, prefix)) do
      [session] -> session
      _ -> nil
    end
  end
end
