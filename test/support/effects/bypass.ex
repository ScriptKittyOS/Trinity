# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestEffects.Bypass do
  @moduledoc """
  A planted bypass of the membrane (slice 024 AC1, the F6 pattern): a module that calls an
  effectful tool's `execute/2` directly. The census must name it. Never called by product code.
  """

  @doc "Runs the tool without the membrane. The census must flag this call."
  def run(module, args, ctx), do: module.execute(args, ctx)
end
