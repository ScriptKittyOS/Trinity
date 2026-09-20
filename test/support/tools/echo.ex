# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.Echo do
  @moduledoc "Slice 020: returns its `text` argument. The registry's smallest possible tool."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.Result

  @impl true
  def name, do: "echo"
  @impl true
  def description, do: "Returns the text it is given."
  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none
  @impl true
  def execute(%{"text" => text}, _ctx), do: {:ok, Result.text(text)}
end
