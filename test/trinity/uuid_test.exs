# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.UUIDTest do
  use ExUnit.Case, async: true

  alias Trinity.UUID

  test "is 36 characters in the canonical form with version 7 and the RFC variant" do
    uuid = UUID.generate()
    assert String.length(uuid) == 36
    assert String.at(uuid, 14) == "7"
    assert String.at(uuid, 19) in ["8", "9", "a", "b"]

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             uuid
           )
  end

  test "carries the current time to the millisecond" do
    before = System.system_time(:millisecond)
    {:ok, ms} = UUID.timestamp_ms(UUID.generate())
    after_ = System.system_time(:millisecond)
    assert before <= ms and ms <= after_
  end

  test "1000 ids minted in a tight loop are unique and sort in mint order" do
    ids = for _ <- 1..1000, do: UUID.generate()
    assert length(Enum.uniq(ids)) == 1000
    assert ids == Enum.sort(ids)
  end

  test "ids minted from many processes at once are unique" do
    ids =
      1..50
      |> Task.async_stream(fn _ -> for _ <- 1..100, do: UUID.generate() end, max_concurrency: 50)
      |> Enum.flat_map(fn {:ok, list} -> list end)

    assert length(Enum.uniq(ids)) == 5000
  end

  test "timestamp_ms refuses anything that is not a v7 uuid" do
    assert :error = UUID.timestamp_ms("not-a-uuid")
    assert :error = UUID.timestamp_ms("123e4567-e89b-12d3-a456-426614174000")
  end
end
