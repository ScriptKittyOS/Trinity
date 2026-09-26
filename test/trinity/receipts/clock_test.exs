# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.ClockTest do
  @moduledoc """
  Slice 026: the hybrid logical clock is monotone even when the host's wall clock is not.

  The property that matters is the one a partition depends on: a chain's clocks never go backwards,
  whatever the machine underneath does. Everything else the clock offers is an assertion about an
  untrusted reading, and the moduledoc says so.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Receipts.Clock

  test "the first clock of a chain takes the wall reading" do
    c = Clock.next(nil, 1_000)
    assert c.wall == 1_000
    assert c.counter == 0
    assert c.node == Clock.node_id()
  end

  test "a wall reading that moved forward resets the counter" do
    prev = %Clock{wall: 1_000, counter: 7, node: Clock.node_id()}
    assert %Clock{wall: 2_000, counter: 0} = Clock.next(prev, 2_000)
  end

  test "a wall reading that stood still increments the counter" do
    prev = %Clock{wall: 1_000, counter: 0, node: Clock.node_id()}
    assert %Clock{wall: 1_000, counter: 1} = Clock.next(prev, 1_000)
  end

  test "a wall clock that went BACKWARDS still produces a greater clock" do
    # The case the whole design exists for. A host whose clock steps back must not be able to
    # produce a receipt that appears to precede one it already wrote.
    prev = %Clock{wall: 5_000, counter: 0, node: Clock.node_id()}
    next = Clock.next(prev, 1_000)

    assert next.wall == 5_000, "the clock followed the wall backwards"
    assert next.counter == 1
    assert Clock.compare(next, prev) == :gt
  end

  property "next/2 is strictly greater than its predecessor, for any sequence of wall readings" do
    check all(walls <- list_of(integer(0..10_000), min_length: 1, max_length: 40)) do
      {_last, pairs} =
        Enum.reduce(walls, {nil, []}, fn wall, {prev, acc} ->
          next = Clock.next(prev, wall)
          {next, [{prev, next} | acc]}
        end)

      for {prev, next} <- pairs, prev != nil do
        assert Clock.compare(next, prev) == :gt,
               "clock went backwards or stalled: #{inspect(prev)} then #{inspect(next)}"
      end
    end
  end

  describe "compare/2" do
    test "orders by wall, then counter, then node" do
      a = %Clock{wall: 1, counter: 0, node: "a"}
      assert Clock.compare(a, %Clock{wall: 2, counter: 0, node: "a"}) == :lt
      assert Clock.compare(a, %Clock{wall: 1, counter: 1, node: "a"}) == :lt
      assert Clock.compare(a, %Clock{wall: 1, counter: 0, node: "b"}) == :lt
      assert Clock.compare(a, a) == :eq
    end

    property "it is a total order: exactly one of lt, eq, gt, and it is antisymmetric" do
      gen = fn -> {integer(0..100), integer(0..10), member_of(["a", "b", "c"])} end
      {w, c, n} = gen.()

      check all(
              a <- map({w, c, n}, fn {w, c, n} -> %Clock{wall: w, counter: c, node: n} end),
              b <- map({w, c, n}, fn {w, c, n} -> %Clock{wall: w, counter: c, node: n} end)
            ) do
        case Clock.compare(a, b) do
          :eq -> assert Clock.compare(b, a) == :eq
          :lt -> assert Clock.compare(b, a) == :gt
          :gt -> assert Clock.compare(b, a) == :lt
        end
      end
    end
  end

  describe "concurrent?/2" do
    test "same device is never concurrent with itself" do
      a = %Clock{wall: 1, counter: 0, node: "a"}
      refute Clock.concurrent?(a, a)
    end

    test "different devices at the same reading are concurrent" do
      assert Clock.concurrent?(
               %Clock{wall: 1, counter: 0, node: "a"},
               %Clock{wall: 1, counter: 0, node: "b"}
             )
    end

    test "different devices at different readings are ordered, not concurrent" do
      refute Clock.concurrent?(
               %Clock{wall: 1, counter: 0, node: "a"},
               %Clock{wall: 2, counter: 0, node: "b"}
             )
    end
  end

  describe "the signed form" do
    test "round-trips through the payload shape" do
      c = %Clock{wall: 123, counter: 4, node: "dev"}
      assert {:ok, ^c} = c |> Clock.to_map() |> Clock.from_map()
    end

    test "to_map/1 carries string keys and nothing else, so it canonicalises" do
      m = Clock.to_map(%Clock{wall: 1, counter: 2, node: "d"})
      assert Map.keys(m) |> Enum.sort() == ["counter", "node", "wall"]
      assert is_binary(Jcs.encode(m))
    end

    test "from_map/1 refuses a shape that is not a clock" do
      assert Clock.from_map(%{"wall" => -1, "counter" => 0, "node" => "d"}) == :error
      assert Clock.from_map(%{"wall" => 1, "counter" => 0}) == :error
      assert Clock.from_map(%{"wall" => "1", "counter" => 0, "node" => "d"}) == :error
      assert Clock.from_map(nil) == :error
    end
  end

  test "the device id is stable across calls" do
    assert Clock.node_id() == Clock.node_id()
    assert byte_size(Clock.node_id()) > 8
  end
end
