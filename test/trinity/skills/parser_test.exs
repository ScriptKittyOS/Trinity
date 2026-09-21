# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.ParserTest do
  @moduledoc "Slice 040, AC1: a fixture directory into a %Skill{} with its frontmatter, body, references and manifest; malformed frontmatter refused by name."
  use ExUnit.Case, async: true

  alias Trinity.Skills.{Parser, Skill, Sources}

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  test "AC1: the bundled fixture parses: frontmatter, category from metadata, body, references, digest and manifest" do
    dir = Path.join(@fixtures, "bundled/echo-skill")
    assert {:ok, %Skill{} = s} = Parser.parse_dir(dir)
    assert s.name == "echo-skill"
    assert s.description =~ "A bundled fixture skill that echoes."
    assert s.category == "testing"
    assert s.metadata == %{"category" => "testing"}
    assert s.body =~ "# Echo (bundled)"
    assert s.references == ["references/notes.md"]
    assert s.scripts == []
    assert s.path == dir
    assert s.body_hash == Parser.digest(File.read!(Path.join(dir, "SKILL.md")))
    assert Map.keys(s.manifest) |> Enum.sort() == ["SKILL.md", "references/notes.md"]
    assert s.manifest["references/notes.md"] == Parser.digest("The bundled reference.\n")
    assert Skill.one_line(s) == "A bundled fixture skill that echoes."
  end

  test "the three bundled skills parse and carry their Trinity keys" do
    for name <- ~w(git-workflow elixir-project-conventions web-research) do
      dir = Path.join(:code.priv_dir(:trinity) |> to_string(), "skills/#{name}")
      assert {:ok, %Skill{name: ^name} = s} = Parser.parse_dir(dir), name
      assert s.license == "Apache-2.0"
      assert s.references != []
      assert Skill.requires_toolsets(s) != []
      assert s.trinity["risk"] in ["read", "write"]
    end
  end

  test "AC1: malformed frontmatter is refused with a descriptive reason, one per fault" do
    bad = Path.join(@fixtures, "bad")
    assert {:error, {:no_frontmatter, msg}} = Parser.parse_dir(Path.join(bad, "no-frontmatter"))
    assert msg =~ "---"
    assert {:error, {:name, msg}} = Parser.parse_dir(Path.join(bad, "bad-name"))
    assert msg =~ "Bad_Name"
    assert {:error, {:name, msg}} = Parser.parse_dir(Path.join(bad, "wrong-dir"))
    assert msg =~ "does not match its directory"

    assert {:error, {:description, "longer than 1024 characters"}} =
             Parser.parse_dir(Path.join(bad, "long-description"))

    assert {:error, {:yaml, _}} = Parser.parse_dir(Path.join(bad, "bad-yaml"))
    assert {:error, {:no_skill_md, _}} = Parser.parse_dir(Path.join(bad, "nowhere"))
  end

  test "the spec's constraints on name, description, compatibility, metadata, allowed-tools and the trinity keys" do
    ok = fn fm -> Parser.parse("---\n" <> fm <> "\n---\n\nbody", "good-name") end

    assert {:ok, %Skill{allowed_tools: ["Bash(git:*)", "Read"], compatibility: "Needs git"}} =
             ok.(
               "name: good-name\ndescription: d\ncompatibility: Needs git\nallowed-tools: Bash(git:*) Read"
             )

    assert {:error, {:name, _}} = ok.("name: good--name\ndescription: d")
    assert {:error, {:name, _}} = ok.("name: -good-name\ndescription: d")
    assert {:error, {:name, "missing"}} = ok.("description: d")
    assert {:error, {:description, "missing"}} = ok.("name: good-name")
    assert {:error, {:description, "empty"}} = ok.("name: good-name\ndescription: '  '")

    assert {:error, {:compatibility, _}} =
             ok.("name: good-name\ndescription: d\ncompatibility: " <> String.duplicate("x", 501))

    assert {:error, {:metadata, _}} = ok.("name: good-name\ndescription: d\nmetadata: [a, b]")

    assert {:error, {:allowed_tools, _}} =
             ok.("name: good-name\ndescription: d\nallowed-tools: [a]")

    assert {:error, {:risk, _}} =
             ok.("name: good-name\ndescription: d\ntrinity:\n  risk: nuclear")

    assert {:error, {:requires_tools, _}} =
             ok.("name: good-name\ndescription: d\ntrinity:\n  requires_tools: 7")

    # Unknown top-level keys and unknown trinity keys are ignored, not refused (forward compatibility).
    assert {:ok, %Skill{trinity: %{"risk" => "read"}}} =
             ok.(
               "name: good-name\ndescription: d\nfuture: yes\ntrinity:\n  risk: read\n  unknown: 1"
             )

    assert {:ok, %Skill{category: "ops"}} =
             ok.("name: good-name\ndescription: d\ntrinity:\n  category: Ops")
  end

  test "a skill whose files do not match its manifest is refused by the source loader, not the parser" do
    dir = Path.join(@fixtures, "mismatch/tampered")
    assert {:ok, %Skill{}} = Parser.parse_dir(dir)

    assert {:error, {:manifest_mismatch, %{changed: ["SKILL.md"], unrecorded: []}}} =
             Sources.load(dir)

    {skills, errors} =
      Sources.scan(%{source: "user", scope: "account", dir: Path.join(@fixtures, "mismatch")})

    assert skills == []
    assert [%{dir: ^dir, reason: {:manifest_mismatch, _}}] = errors
  end

  test "a scan keeps the good skills beside the bad ones' errors" do
    {skills, errors} =
      Sources.scan(%{source: "user", scope: "account", dir: Path.join(@fixtures, "bad")})

    assert skills == []
    assert length(errors) == 5

    {skills, []} =
      Sources.scan(%{source: "bundled", scope: "global", dir: Path.join(@fixtures, "bundled")})

    assert [%Skill{name: "echo-skill", source: "bundled", scope: "global"}] = skills
  end
end
