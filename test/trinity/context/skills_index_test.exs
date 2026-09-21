# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Context.SkillsIndexTest do
  @moduledoc "Slice 040, AC6: the skills index in the prompt's context tier, after the AGENTS.md block, under its cap; a project's skills for that project's session."
  use Trinity.SessionCase

  alias Trinity.Context.SkillsIndex
  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions.{Prompt, Session}
  alias Trinity.Skills.Registry

  @now ~U[2026-09-21 09:00:00Z]

  setup do
    Registry.rescan()
    :ok
  end

  test "AC6: the prompt snapshot carries the skills index in the context tier, after the project instructions" do
    dir = Path.join(System.tmp_dir!(), "trinity-skills-ctx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".trinity/skills/project-only"))
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "AGENTS.md"), "# Project\n- rule one")

    File.write!(
      Path.join(dir, ".trinity/skills/project-only/SKILL.md"),
      "---\nname: project-only\ndescription: A skill of this project alone. Use here.\nmetadata:\n  category: testing\n---\n\nbody\n"
    )

    persona = Factory.persona!()
    session = Factory.session!(%{persona_id: persona.id, project_root: dir})

    block = SkillsIndex.render(dir)
    assert block =~ "## Skills\n"

    assert block =~
             "testing:\n- echo-skill: The user's own echo skill, which shadows the bundled one.\n- project-only: A skill of this project alone."

    refute block =~ "needs-missing-tool"
    assert SkillsIndex.render(nil) =~ "echo-skill"
    refute SkillsIndex.render(nil) =~ "project-only"

    context = Trinity.Context.AgentsMd.render(dir, dir) <> "\n\n" <> block

    {request, []} =
      Prompt.build_with_report(session, persona, [], [], now: @now, context: context)

    assert request.system =~
             ~r/## Project instructions \(AGENTS.md\).*rule one.*<\/untrusted>\n\n## Skills\n.*testing:\n- echo-skill/s

    assert Trinity.Memory.Tokens.estimate(block) <= 338

    # Through a Session: the index is in the request the fake received.
    Fake.scripts([script_deltas(1, "ok ")])
    {:ok, pid} = start_drained(session.id)
    {:ok, _} = Session.send_user_message(pid, "hi")
    _ = collect(session.id, &match?({:state, :idle}, &1))
    system = Fake.last_request().system
    assert system =~ ~r/## Skills\n.*testing:\n- echo-skill/s
    assert system =~ "- project-only: A skill of this project alone."
    assert system =~ "- rule one"
  end

  test "a session without a project still carries the global skills, and none when every skill is disabled" do
    persona = Factory.persona!()
    session = Factory.session!(%{persona_id: persona.id})
    Fake.scripts([script_deltas(1, "ok "), script_deltas(1, "ok ")])
    {:ok, pid} = start_drained(session.id)
    {:ok, _} = Session.send_user_message(pid, "hi")
    _ = collect(session.id, &match?({:state, :idle}, &1))
    assert Fake.last_request().system =~ ~r/## Skills\n.*testing:\n- echo-skill/s

    for s <- Trinity.Skills.list(),
        do: :ok = Trinity.Skills.set_status(s.name, s.source, "disabled")

    on_exit(fn ->
      Registry.rescan()
      for s <- Trinity.Skills.list(), do: Trinity.Skills.set_status(s.name, s.source, "active")
    end)

    {:ok, _} = Session.send_user_message(pid, "again")
    _ = collect(session.id, &match?({:state, :idle}, &1))
    refute Fake.last_request().system =~ "## Skills"
  end
end
