# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Property.FindsWhatExamplesMissTest do
  @moduledoc """
  Slice 004 AC6: a defect that the example tests pass over and generated input finds.

  Without this the slice proves only that some properties hold, which is worth much less: a suite of
  properties that all pass on the first run is indistinguishable from a suite that could never fail.

  The planted defect is the classic one for this kind of code, and it is planted here rather than in
  the real module so the demonstration is committed and reproducible rather than a story about a
  patch someone once applied. `Defective` builds its digest by **concatenating fields without a
  separator**, which is how a canonicaliser is usually got wrong: it looks right, it is stable, it
  is order-independent, and it silently identifies two different definitions whenever a boundary
  moves between adjacent fields.

  The two tests below run the same search against the defective canonicaliser and the real one. The
  example-style test uses the same fixtures the real example tests use, and passes on the defect.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Tools.DefinitionDigest

  defmodule Defective do
    @moduledoc false
    # The defect: `name <> description` with nothing between them.
    def of(listed) do
      payload =
        to_string(Map.get(listed, "name")) <>
          to_string(Map.get(listed, "description")) <>
          Jason.encode!(Map.get(listed, "inputSchema") || %{})

      :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    end
  end

  defp listed(name, description),
    do: %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object"}}

  # A pair of definitions that differ, built by moving the boundary between two adjacent fields.
  defp boundary_pair(left, right) do
    {listed(left, right), listed(left <> right, "")}
  end

  test "the example tests pass on the defective canonicaliser, which is why they are not enough" do
    # These are the fixtures the real example suite uses: a name, a description, a changed
    # description, a changed schema. Every one of them holds against the defect.
    a = listed("read_file", "Reads a file.")
    b = listed("read_file", "Reads a file. And /etc/shadow.")

    assert Defective.of(a) == Defective.of(a)
    refute Defective.of(a) == Defective.of(b)

    refute Defective.of(a) ==
             Defective.of(%{a | "inputSchema" => %{"type" => "string"}})
  end

  test "generated input finds a collision in the defective canonicaliser" do
    collisions =
      for left <- ["a", "read", "tool", "x"],
          right <- ["b", "_file", "s", ""],
          {one, other} = boundary_pair(left, right),
          one != other,
          Defective.of(one) == Defective.of(other),
          do: {one["name"], one["description"]}

    assert collisions != [],
           "the planted defect did not collide, so this test demonstrates nothing"
  end

  property "the real canonicaliser has no collision anywhere in that same space" do
    check all(
            left <- string(:alphanumeric, min_length: 1, max_length: 8),
            right <- string(:alphanumeric, max_length: 8)
          ) do
      {one, other} = boundary_pair(left, right)

      if one != other do
        refute DefinitionDigest.of(one) == DefinitionDigest.of(other),
               "two different definitions share a digest: #{inspect(one)} and #{inspect(other)}. " <>
                 "A server could then change a tool into a different tool without drifting"
      end
    end
  end
end
