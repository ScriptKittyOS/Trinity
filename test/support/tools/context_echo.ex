# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.ContextEcho do
  @moduledoc """
  Slice 060: a module registered with a spec, serving whatever name the spec gave; it
  answers with the tool name the context carries, which is how one module serves many tools.
  """
  @behaviour Trinity.Tools.Tool

  @impl true
  def name, do: "mcp:"
  @impl true
  def description, do: "the module's own description, unread when a spec is present"
  @impl true
  def schema, do: %{"type" => "object"}
  @impl true
  def risk, do: :ask
  @impl true
  def effect, do: :none
  @impl true
  def execute(args, ctx),
    do: {:ok, Trinity.Tools.Result.text("#{ctx.tool}:#{args["text"]}")}
end
