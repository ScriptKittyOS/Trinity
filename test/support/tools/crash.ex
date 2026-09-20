# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.Crash do
  @moduledoc "Slice 020: raises, or exits when `how` is \"exit\"."
  @behaviour Trinity.Tools.Tool

  @impl true
  def name, do: "crash"
  @impl true
  def description, do: "Crashes on purpose."
  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"how" => %{"type" => "string"}},
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none
  @impl true
  def execute(%{"how" => "exit"}, _ctx), do: exit(:on_purpose)
  def execute(_args, _ctx), do: raise("the crash tool crashed on purpose")
end
