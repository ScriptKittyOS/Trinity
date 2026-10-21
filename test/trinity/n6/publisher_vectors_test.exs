# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.PublisherVectorsTest do
  # Slice 142 AC5: agreement with the profile publisher's cut vector set (N6 draft v0.1-r7 section
  # 10), opt-in by path, because the set is not posted yet and this tree does not vendor it.
  #
  #     TRINITY_N6_PUBLISHER_VECTORS=<the set's root> mix test --only n6_publisher
  use ExUnit.Case, async: true

  alias Trinity.TestSupport.N6R7Vectors

  @root System.get_env("TRINITY_N6_PUBLISHER_VECTORS")

  @moduletag :n6_publisher

  if @root do
    test "every vector of the cut directories agrees, and the set is the one its SHA384SUMS names" do
      assert N6R7Vectors.sums_defects(@root) == []

      {version, set_digest} = N6R7Vectors.pin(@root)
      results = N6R7Vectors.run(@root)

      IO.puts("\nN6 publisher set: #{version}, SHA-384 of SHA384SUMS #{set_digest}")

      for {dir, {agree, wrong}} <- Enum.sort(results),
          do: IO.puts("  #{dir}: #{agree} of #{agree + length(wrong)} agree")

      wrong =
        for {dir, {_agree, wrong}} <- results,
            {id, want, got} <- wrong,
            do: "#{dir}/#{id}: want #{inspect(want)}, got #{inspect(got)}"

      assert wrong == [], Enum.join(Enum.sort(wrong), "\n")
    end
  else
    @tag skip: "set TRINITY_N6_PUBLISHER_VECTORS to the publisher's vectors/n6 to run this"
    test "every vector of the cut directories agrees, and the set is the one its SHA384SUMS names" do
    end
  end
end
