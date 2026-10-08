# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SpacesHelper do
  @moduledoc """
  Test-only: points a store's active space at a space directly, standing in for an operator's
  completed re-tier where a test needs a store already pinned somewhere (slice 133). Nothing in
  `lib/` moves the pointer this way; `Trinity.Memory.Spaces.retier/2` is the operator's path.
  """
  import Ecto.Query

  alias Trinity.Memory.{Space, SpaceRow, Spaces}
  alias Trinity.Repo

  @doc "Registers the space and makes it the only active one."
  @spec pin!(Space.t()) :: SpaceRow.t()
  def pin!(%Space{} = space) do
    {:ok, row} = Spaces.register(space)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.update_all(from(s in SpaceRow, where: s.active == true), set: [active: false])
        Repo.update_all(from(s in SpaceRow, where: s.id == ^row.id), set: [active: true])
      end)

    Spaces.get(row.id)
  end
end
