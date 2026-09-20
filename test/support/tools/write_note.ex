# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.WriteNote do
  @moduledoc "Slice 021: a write-risk tool that writes nothing; the gate asks before it runs."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.Result

  @impl true
  def name, do: "write_note"
  @impl true
  def description, do: "Pretends to write a note at a path."
  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}, "text" => %{"type" => "string"}},
      "required" => ["path"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :write
  @impl true
  def effect, do: :artifact
  @impl true
  def execute(%{"path" => path} = args, _ctx),
    do: {:ok, Result.text("wrote #{byte_size(Map.get(args, "text", ""))} bytes to #{path}")}
end
