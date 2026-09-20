# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects.Catalog do
  @moduledoc """
  The effect catalog, resolved at compile time (docs/07, M4). Slice 020 opened it empty;
  slice 022 lists the shell, an external effect under local authority (its alignment note).

  Every tool whose `effect/0` is `:catalog` (an external effect: send, spend, a provider
  mutation) is listed here by name with its risk tier, in a module attribute and nowhere
  else. `Trinity.Tools.Registry` admits a core `:catalog` tool only if its name is in this
  list and refuses a runtime registration claiming `:catalog` outright; the census test
  (slice 020 AC8) walks the tree and asserts no other path admits one. Slice 024 makes the
  membrane read it.
  """

  @catalog [{"shell", :exec}]

  @doc "Every catalog tool as `{name, tier}`."
  @spec all() :: [{String.t(), atom()}]
  def all, do: @catalog

  @doc "The names alone."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@catalog, &elem(&1, 0))
end
