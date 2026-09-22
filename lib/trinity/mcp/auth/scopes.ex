# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Scopes do
  @moduledoc """
  What a scope lets a token do (slice 062, AC4), checked before the permission gate: a tool
  whose effect is `:none` needs `trinity:tools:read` (`trinity:recall` is its alias, the SLICE's
  word); an `:artifact` tool needs `trinity:tools:artifact`. A `:catalog` tool is never
  exportable (061), so no scope names it. The gate still decides afterwards: a scope is what
  the token may ask for, not what happens.
  """

  @read ~w(trinity:tools:read trinity:recall)
  @artifact ~w(trinity:tools:artifact)

  @doc "The scopes this server understands."
  @spec known() :: [String.t()]
  def known, do: @read ++ @artifact

  @doc "True when the scopes cover a call to a tool of that effect."
  @spec covers?([String.t()], :none | :artifact | :catalog) :: boolean()
  def covers?(scopes, :none),
    do: Enum.any?(scopes, &(&1 in @read)) or Enum.any?(scopes, &(&1 in @artifact))

  def covers?(scopes, :artifact), do: Enum.any?(scopes, &(&1 in @artifact))
  def covers?(_scopes, :catalog), do: false

  @doc "The scope a tool of that effect needs, for a refusal's message."
  @spec required(:none | :artifact | :catalog) :: String.t()
  def required(:none), do: "trinity:tools:read"
  def required(:artifact), do: "trinity:tools:artifact"
  def required(:catalog), do: "(none: not exportable)"
end
