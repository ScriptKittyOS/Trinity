# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.CorePolicy do
  @moduledoc """
  A digest over the object code of the modules that decide what the agent may do. Slice 012
  introduces it because AC9 (kill and reseed) asserts it; slice 024 extends the list and writes it
  into the boot receipt. A reseeded Session is born from this hash and nothing else in process
  state.
  """

  @modules [
    Trinity.Sessions.Session,
    Trinity.Sessions.Caps,
    Trinity.Sessions.ToolRunner,
    Trinity.Sessions.ToolRunner.Stub,
    Trinity.Sessions.Sentinel
  ]

  @doc "The modules the hash covers, in order."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc "SHA-256, hex, over the concatenated object code of `modules/0`."
  @spec hash() :: String.t()
  def hash do
    @modules
    |> Enum.map(fn mod ->
      {^mod, binary, _path} = :code.get_object_code(mod)
      binary
    end)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
