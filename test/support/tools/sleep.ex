# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.Sleep do
  @moduledoc "Slice 020: sleeps `ms` milliseconds, then answers. Its timeout is 500 ms."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.Result

  @impl true
  def name, do: "sleep"
  @impl true
  def description, do: "Waits the given milliseconds."
  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"ms" => %{"type" => "integer", "minimum" => 0}},
      "required" => ["ms"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none
  @impl true
  def timeout, do: 500
  @impl true
  def execute(%{"ms" => ms}, _ctx) do
    Process.sleep(ms)
    {:ok, Result.text("slept #{ms}")}
  end
end
