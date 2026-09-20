# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.DataDir.LockBootTest do
  @moduledoc """
  Slice 010 AC6, the boot half: the running application holds its lock, the lock child sits
  before the Repo in the supervision tree, and a second acquire of the application's own
  directory is refused naming this VM's OS pid.
  """
  use ExUnit.Case, async: false

  alias Trinity.DataDir.Lock

  test "the application holds the configured directory" do
    dir = Application.fetch_env!(:trinity, Lock)[:dir]
    assert {:ok, holder} = Lock.holder(dir)
    assert holder.pid == String.to_integer(System.pid())
    assert holder.mode == :desktop
    assert {:error, {:held, ^holder}} = Lock.acquire(dir, :headless)
  end

  test "the lock child starts before the Repo" do
    ids =
      Supervisor.which_children(Trinity.Supervisor) |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    assert Enum.find_index(ids, &(&1 == Lock)) < Enum.find_index(ids, &(&1 == Trinity.Repo))
  end
end
