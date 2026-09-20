# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestTools.DynamicEcho do
  @moduledoc "Slice 020: a dynamic tool, namespaced as an MCP server's, otherwise the echo tool."
  @behaviour Trinity.Tools.Tool

  @impl true
  def name, do: "mcp:fake:echo"
  @impl true
  def description, do: Trinity.TestTools.Echo.description()
  @impl true
  def schema, do: Trinity.TestTools.Echo.schema()
  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none
  @impl true
  def execute(args, ctx), do: Trinity.TestTools.Echo.execute(args, ctx)
end
