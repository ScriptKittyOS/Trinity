# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.RuleTest do
  @moduledoc "Slice 021: the pattern language of tool_permissions rows."
  use ExUnit.Case, async: true

  alias Trinity.Permissions.Rule

  test "* matches anything; fp: matches the fingerprint only" do
    assert Rule.matches?("*", %{"x" => 1}, nil)
    assert Rule.matches?("fp:abc", %{}, "abc")
    refute Rule.matches?("fp:abc", %{}, "abd")
  end

  test "key=glob: * within a segment, ** across, ? one character, a trailing * is a prefix" do
    assert Rule.matches?("path=/home/me/notes/*.md", %{"path" => "/home/me/notes/a.md"}, nil)
    refute Rule.matches?("path=/home/me/notes/*.md", %{"path" => "/home/me/notes/sub/a.md"}, nil)
    assert Rule.matches?("path=/home/me/**", %{"path" => "/home/me/notes/sub/a.md"}, nil)
    refute Rule.matches?("path=/home/me/**", %{"path" => "/etc/passwd"}, nil)
    assert Rule.matches?("command=git *", %{"command" => "git status"}, nil)
    refute Rule.matches?("command=git *", %{"command" => "rm -rf /"}, nil)
    assert Rule.matches?("n=?", %{"n" => 7}, nil)
    refute Rule.matches?("path=/a", %{"other" => "/a"}, nil)
  end

  test "re: is accepted from a hand-edited row; a broken regex matches nothing" do
    assert Rule.matches?("re:^git (status|log)$", %{"command" => "git log"}, nil)
    refute Rule.matches?("re:[", %{"command" => "x"}, nil)
  end

  test "the changeset refuses a pattern outside the language and a scope outside the vocabulary" do
    ok =
      Rule.changeset(%Rule{}, %{
        tool: "t",
        pattern: "path=/x/*",
        decision: "allow",
        scope: "global"
      })

    assert ok.valid?

    bad =
      Rule.changeset(%Rule{}, %{
        tool: "t",
        pattern: "nonsense",
        decision: "allow",
        scope: "global"
      })

    refute bad.valid?
    bad2 = Rule.changeset(%Rule{}, %{tool: "t", pattern: "*", decision: "maybe", scope: "team"})
    assert Keyword.has_key?(bad2.errors, :decision) and Keyword.has_key?(bad2.errors, :scope)
  end
end
