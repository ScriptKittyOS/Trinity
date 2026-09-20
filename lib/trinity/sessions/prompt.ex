# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Prompt do
  @moduledoc """
  Builds the `Trinity.LLM.Request` for a turn, and nothing else. Slice 012. Pure: the caller
  passes the session, its persona and the history; this module reads no table. The system
  prompt is the persona's soul (a stub until slice 030) followed by an always-on memory stub;
  slices 030 and 040 add the tiers and the skills index in the order docs/07 fixes.
  """

  alias Trinity.LLM.Request
  alias Trinity.Sessions.{Message, Persona, SessionRow}

  @doc "The request for the next model call; `tools` is the declared surface (slice 020), none by default."
  @spec build(SessionRow.t(), Persona.t() | nil, [Message.t()], [Request.tool()]) :: Request.t()
  def build(%SessionRow{} = session, persona, history, tools \\ []) do
    Request.new!(%{
      system: system(persona),
      messages: Enum.map(history, &message/1),
      tools: tools,
      model: session.model || (persona && persona.model),
      params: %{}
    })
  end

  defp system(nil), do: "You are Trinity."
  defp system(%Persona{soul: soul}) when is_binary(soul) and soul != "", do: soul
  defp system(%Persona{}), do: "You are Trinity."

  defp message(%Message{role: "tool"} = m),
    do: %{role: "tool", content: m.content, tool_call_id: m.tool_call_id}

  defp message(%Message{role: "assistant"} = m) do
    case get_in(m.parts, ["tool_calls"]) do
      calls when is_list(calls) and calls != [] ->
        %{
          role: "assistant",
          content: m.content,
          tool_calls: Enum.map(calls, &%{id: &1["id"], name: &1["name"], args: &1["args"] || %{}})
        }

      _ ->
        %{role: "assistant", content: m.content}
    end
  end

  defp message(%Message{role: role, content: content}), do: %{role: role, content: content}
end
