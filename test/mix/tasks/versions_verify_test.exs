# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Versions.VerifyTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Versions.Verify

  test "a pin the lock disagrees with is reported, naming the package" do
    pins = [%{name: "boundary", pin: "~> 9.9", note: "planted"}]
    locked = %{"boundary" => "0.10.4"}

    assert [msg] = Verify.problems(pins, locked)
    assert msg =~ "boundary", "the message must name the package: #{msg}"
    assert msg =~ "~> 9.9" and msg =~ "0.10.4"
  end

  test "a pin absent from the lock is reported, naming the package" do
    assert [msg] = Verify.problems([%{name: "ghost", pin: "~> 1.0", note: ""}], %{})
    assert msg =~ "ghost" and msg =~ "absent from mix.lock"
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
