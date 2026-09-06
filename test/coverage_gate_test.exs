# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule CoverageGateTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Trinity.Coverage

  @moduledoc "docs/03: a drop of more than three points fails until NOTES.md names the reason."

  test "a drop of more than three points fails" do
    assert {:error, drop} = Coverage.compare(80.0, 76.5)
    assert_in_delta drop, 3.5, 0.001
  end

  test "a drop of exactly three points passes" do
    assert :ok = Coverage.compare(80.0, 77.0)
  end

  test "a rise passes" do
    assert :ok = Coverage.compare(70.0, 91.2)
  end

  test "rows/1 parses the tsv and ignores the header and comments" do
    tsv = """
    # a comment
    slice_id\tpercent\tsha\tdate
    000\t81.4\tdeadbeef\t2026-09-06
    001\t79.0\tcafebabe\t2026-09-07
    """

    assert [{"000", 81.4}, {"001", 79.0}] = Coverage.rows(tsv)
  end
end
