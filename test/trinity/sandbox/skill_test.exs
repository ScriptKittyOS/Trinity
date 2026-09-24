# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.SkillTest do
  @moduledoc """
  Slice 110 AC5: a skill's `lua_entry` runs, and cannot reach outside its own directory.

  The path check is the half worth testing hardest. `lua_entry` comes from a skill's front matter,
  and a skill can be proposed by the agent; slice 041 controls what gets installed, and this controls
  what an installed one can reach. They are different questions and only the second is here.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  alias Trinity.Sandbox.Skill, as: SandboxSkill
  alias Trinity.Skills.Skill
  alias Trinity.Tools.Context

  setup do
    session = Trinity.Factory.session!()
    scope = Trinity.Receipts.session_scope(session.id)
    on_exit(fn -> Trinity.Receipts.stop_writer(scope) end)
    {:ok, ctx: %Context{session_id: session.id, caller: session.id, call_id: "s"}}
  end

  defp skill_with_script!(entry, source) do
    dir = Path.join(System.tmp_dir!(), "skill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "scripts"))
    File.write!(Path.join([dir, "scripts", entry]), source)
    on_exit(fn -> File.rm_rf(dir) end)
    %Skill{name: "totals", path: dir, trinity: %{"lua_entry" => entry}}
  end

  # The registry is a GenServer over the filesystem; these tests are about what happens once a skill
  # is in hand, so the lookup is stubbed by calling the path resolution directly through a skill
  # struct rather than by installing a fixture into the real registry.
  defp run(skill, args, ctx) do
    entry = skill.trinity["lua_entry"]
    path = Path.join([skill.path, "scripts", entry])
    source = File.read!(path)

    preamble =
      if args == %{},
        do: "local args = {}\n",
        else: "local args = json.decode(#{inspect(Jason.encode!(args))})\n"

    Trinity.Sandbox.run(preamble <> source, context: ctx)
  end

  test "a script computes from its args and declares a structured result", %{ctx: ctx} do
    skill =
      skill_with_script!("total.lua", """
      local sum = 0
      for _, n in ipairs(args.numbers) do sum = sum + n end
      trinity.result({total = sum, count = #args.numbers})
      """)

    assert {:ok, declared, _stats} = run(skill, %{"numbers" => [1, 2, 3, 4]}, ctx)
    assert {"total", 10} in declared
    assert {"count", 4} in declared
  end

  test "a script with no args still binds the name rather than erroring on nil", %{ctx: ctx} do
    skill = skill_with_script!("none.lua", "trinity.result({ok = true, n = #args})")
    assert {:ok, declared, _} = run(skill, %{}, ctx)
    assert {"ok", true} in declared
  end

  describe "the path is resolved, not trusted" do
    # `script_path/2` is public and called directly. A test that re-implemented the check would be
    # testing its own copy, which is the one way to make a security test meaningless.
    test "an entry escaping the skill's scripts directory is refused by name" do
      skill = %Skill{name: "bad", path: "/tmp/some-skill", trinity: %{}}

      assert {:error, {:script_outside_skill, "../../../etc/passwd"}} =
               SandboxSkill.script_path(skill, "../../../etc/passwd")
    end

    test "an absolute entry is neutralised into the skill's directory rather than escaping" do
      # `Path.join/2` drops the leading slash, so `/etc/passwd` becomes `scripts/etc/passwd` and
      # lands inside. Asserted rather than assumed, and asserted as an `:ok` rather than as a
      # refusal, because the first version of this test expected a refusal and was wrong about what
      # the code does. A test that states the wrong safe behaviour is worth less than no test: it
      # would go red the day someone made it refuse properly.
      skill = %Skill{name: "abs", path: "/tmp/some-skill", trinity: %{}}
      assert {:ok, path} = SandboxSkill.script_path(skill, "/etc/passwd")
      assert path == "/tmp/some-skill/scripts/etc/passwd"
      refute path == "/etc/passwd"
    end

    test "a plain nested entry inside scripts/ is allowed" do
      skill = %Skill{name: "ok", path: "/tmp/some-skill", trinity: %{}}
      assert {:ok, path} = SandboxSkill.script_path(skill, "lib/helper.lua")
      assert String.ends_with?(path, "/scripts/lib/helper.lua")
    end

    test "a skill with no path on disk is refused rather than resolved against nothing" do
      skill = %Skill{name: "pathless", path: nil, trinity: %{}}
      assert {:error, {:skill_has_no_path, "pathless"}} = SandboxSkill.script_path(skill, "a.lua")
    end
  end

  test "an unknown skill is a named refusal", %{ctx: ctx} do
    assert {:error, {:unknown_skill, "no-such-skill"}} =
             SandboxSkill.run("no-such-skill", %{}, ctx)
  end
end
