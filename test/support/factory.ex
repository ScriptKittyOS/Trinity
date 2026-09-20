# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Factory do
  @moduledoc """
  Plain functions that insert rows for tests. Slice 010. No factory library: three functions
  are cheaper to read than a DSL, and every attribute they set is visible here.
  """
  alias Trinity.Sessions

  @spec persona!(map()) :: Sessions.Persona.t()
  def persona!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "persona-#{System.unique_integer([:positive])}")

    {:ok, persona} =
      Sessions.create_persona(
        Map.merge(%{name: name, soul: "test soul", model: "fake:model"}, attrs)
      )

    persona
  end

  @spec session!(map()) :: Sessions.Session.t()
  def session!(attrs \\ %{}) do
    attrs = Map.put_new_lazy(attrs, :persona_id, fn -> persona!().id end)
    {:ok, session} = Sessions.create_session(attrs)
    session
  end

  @spec message!(String.t(), map()) :: Sessions.Message.t()
  def message!(session_id, attrs \\ %{}) do
    {:ok, message} =
      Sessions.append_message(session_id, Map.merge(%{role: "user", content: "hello"}, attrs))

    message
  end
end
