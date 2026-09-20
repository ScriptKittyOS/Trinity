# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.Big do
  @moduledoc "Slice 020: returns `bytes` bytes of text, more than the cap by default."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.Result

  @impl true
  def name, do: "big"
  @impl true
  def description, do: "Returns a lot of text."
  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"bytes" => %{"type" => "integer"}},
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none
  @impl true
  def execute(args, _ctx) do
    bytes = Map.get(args, "bytes", Result.cap_bytes() * 2)
    {:ok, Result.text(String.duplicate("x", bytes), %{"kind" => "big"})}
  end
end
