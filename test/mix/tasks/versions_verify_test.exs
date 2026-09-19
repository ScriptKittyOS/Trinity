# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Versions.VerifyTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Versions.Verify

  test "a pin the lock disagrees with is reported, naming the package" do
    pins = [%{name: "boundary", pin: "~> 9.9", lock: "boundary", note: "planted"}]
    locked = %{"boundary" => "0.10.4"}

    assert [msg] = Verify.problems(pins, locked)
    assert msg =~ "boundary", "the message must name the package: #{msg}"
    assert msg =~ "~> 9.9" and msg =~ "0.10.4"
  end

  # Semantics corrected at G4: absence is NOT disagreement. Most pinned packages arrive at a
  # later slice and are marked 🔍 in VERSIONS.md until then; failing the gate for work nobody
  # has done would be a false signal.
  test "a pin absent from the lock is NOT reported" do
    assert Verify.problems([%{name: "ghost", pin: "~> 1.0", lock: "ghost", note: ""}], %{}) == []
  end

  test "a pin that is not a version requirement is documentation, not an assertion" do
    pins = [%{name: "telegex", pin: "**not pinned**", lock: "telegex", note: ""}]
    assert Verify.problems(pins, %{"telegex" => "1.9.0-rc.0"}) == []
  end

  test "the real pin list is satisfied by the real lock" do
    locked =
      Mix.Dep.Lock.read()
      |> Enum.flat_map(fn
        {n, t} when is_tuple(t) and elem(t, 0) == :hex -> [{Atom.to_string(n), elem(t, 2)}]
        _ -> []
      end)
      |> Map.new()

    assert Verify.problems(Trinity.Versions.deps(), locked) == []
  end

  test "satisfies?/2 is false for a nil lock and for a non-version string" do
    refute Verify.satisfies?(nil, "~> 1.0")
    refute Verify.satisfies?("not-a-version", "~> 1.0")
  end
end

defmodule Mix.Tasks.Versions.VerifyUndocumentedTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Versions.Verify

  @moduledoc """
  The red is planted through the argument, not through `mix.exs`. Adding an unfetched
  dependency there makes Mix refuse to run at all, so the task never executes and the check
  proves nothing, which is what happened on the first attempt.
  """

  test "RED: a direct dependency with no row is reported" do
    assert ["decimal"] = Verify.undocumented(["phoenix", "decimal", "credo"])
  end

  test "GREEN: a git dependency with no lock key still counts as documented, by name" do
    assert Verify.undocumented(["heroicons", "daisyui"]) == []
  end

  test "the real project has no undocumented direct dependency" do
    assert Verify.undocumented() == [],
           "a slice added a dependency without a row in Trinity.Versions; VERSIONS.md has " <>
             "stopped describing the tree"
  end
end
