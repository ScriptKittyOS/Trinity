# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.CorePolicy do
  @moduledoc """
  A digest over the object code of the modules that decide what the agent may do. Slice 012
  introduces it because AC9 (kill and reseed) asserts it; slice 024 extends the list and writes it
  into the boot receipt. A reseeded Session is born from this hash and nothing else in process
  state.
  """

  # Slice 024 extends the list with the modules that decide whether an effect happens: the
  # gate and its policy, the fingerprint, the catalog, the membrane and its runner, the
  # authority behaviour, its local implementation and its selection, the signer seam. A
  # change to any of them is a different hash in the next boot receipt.
  @modules [
    Trinity.Sessions.Session,
    Trinity.Sessions.Caps,
    Trinity.Sessions.ToolRunner,
    Trinity.Sessions.ToolRunner.Stub,
    Trinity.Sessions.Sentinel,
    Trinity.Permissions,
    Trinity.Permissions.Policy.Layered,
    Trinity.Permissions.Fingerprint,
    Trinity.Permissions.Gate,
    Trinity.Tools.Catalog,
    Trinity.Tools.Runner,
    Trinity.Effects,
    Trinity.Effects.Runner,
    Trinity.Authority,
    Trinity.Authority.Local,
    Trinity.Authority.Selection,
    Trinity.Receipts.KeyCustody,
    Trinity.Receipts.ChainWriter
  ]

  @doc "The modules the hash covers, in order."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc "SHA-256, hex, over the concatenated object code of `modules/0`."
  @spec hash() :: String.t()
  def hash, do: hash_of(@modules)

  @doc "The same digest over any list of loaded modules' object code (the AC6 test plants its own)."
  @spec hash_of([module()]) :: String.t()
  def hash_of(modules) when is_list(modules) do
    modules
    |> Enum.map(fn mod ->
      {^mod, binary, _path} = :code.get_object_code(mod)
      binary
    end)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
