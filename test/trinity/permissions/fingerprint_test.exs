# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.FingerprintTest do
  @moduledoc "Slice 021 line 1: the canonical form is RFC 8785's (the RFC's own vector), and the fingerprint binds every field."
  use ExUnit.Case, async: true

  alias Trinity.Permissions.Fingerprint

  test "jcs matches the RFC 8785 example vector byte for byte" do
    input = "test/support/rfc8785_input.json" |> File.read!() |> Jason.decode!()
    expected = File.read!("test/support/rfc8785_expected.txt")
    assert Fingerprint.canonical(input) == expected
  end

  test "keys are sorted and numbers are ES6 shortest, whatever the map's order" do
    assert Fingerprint.canonical(%{"b" => 1, "a" => %{"z" => 2.0, "y" => [1, "x"]}}) ==
             ~s({"a":{"y":[1,"x"],"z":2},"b":1})
  end

  test "the same call is the same digest; a changed argument, scope or cwd is another" do
    fp = Fingerprint.of("write_note", %{"path" => "/a", "text" => "t"}, "session:1", nil)
    assert fp == Fingerprint.of("write_note", %{"text" => "t", "path" => "/a"}, "session:1", nil)
    assert String.match?(fp, ~r/^[0-9a-f]{64}$/)
    refute fp == Fingerprint.of("write_note", %{"path" => "/b", "text" => "t"}, "session:1", nil)
    refute fp == Fingerprint.of("write_note", %{"path" => "/a", "text" => "t"}, "session:2", nil)

    refute fp ==
             Fingerprint.of("write_note", %{"path" => "/a", "text" => "t"}, "session:1", "/home")

    assert Fingerprint.version() == 1
  end
end
