# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.RegistryTest do
  @moduledoc "Slice 040: AC2 precedence, AC3 hot reload, AC5 conditional activation, the index rows, enable and disable, the manifest refusal."
  use Trinity.DataCase, async: false

  alias Trinity.Skills
  alias Trinity.Skills.{Registry, Row, Skill}

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  setup do
    old = Application.get_env(:trinity, :skills, [])

    on_exit(fn ->
      Application.put_env(:trinity, :skills, old)
      Registry.rescan()
    end)

    Registry.rescan()
    {:ok, old: old}
  end

  defp tmp_user_dir(old) do
    dir = Path.join(System.tmp_dir!(), "skills-user-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Application.put_env(:trinity, :skills, Keyword.put(old, :user_dir, dir))
    dir
  end

  defp write_skill!(root, name, description, extra \\ "") do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{description}\n#{extra}---\n\n# #{name}\n"
    )

    dir
  end

  test "AC2: the same name in user and bundled: user wins and the bundled one is listed as shadowed; the rows carry both" do
    assert %Skill{source: "user", shadows: ["bundled"], body: body} = Skills.get("echo-skill")
    assert body =~ "The user's version wins"

    assert Repo.all(from(r in Row, where: r.name == "echo-skill", select: r.source))
           |> Enum.sort() == ["bundled", "user"]

    assert Enum.map(Skills.list(), & &1.name) ==
             ~w(echo-skill needs-missing-tool needs-shell needs-web no-shell-fallback)
  end

  test "AC2: a project skill wins over the user's, and is visible only to a caller naming that project",
       %{old: _} do
    project = Path.join(System.tmp_dir!(), "skills-project-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(project) end)
    write_skill!(Path.join(project, ".trinity/skills"), "echo-skill", "The project's echo skill.")

    assert %Skill{source: "project", scope: "project", shadows: ["user", "bundled"]} =
             Skills.get("echo-skill", project_root: project)

    assert %Skill{source: "user"} = Skills.get("echo-skill")
    assert Repo.get_by(Row, name: "echo-skill", source: "project").scope == "project"
  end

  test "AC5: conditional activation hides a skill whose tool or toolset is absent and shows a fallback only when its toolset has no tool" do
    names = Skills.active() |> Enum.map(& &1.name)
    refute "needs-missing-tool" in names
    refute "needs-web" in names
    shell? = Trinity.Tools.list(toolset: :shell) != []
    assert "needs-shell" in names == shell?
    assert "no-shell-fallback" in names == not shell?
    assert "echo-skill" in names
  end

  test "the index rows: a status survives a rescan, a body change bumps the version, a removed skill's row goes",
       %{old: old} do
    dir = tmp_user_dir(old)
    skill_dir = write_skill!(dir, "temp-skill", "Temporary.")
    Registry.rescan()
    assert %Skill{version: 1, status: "active", source: "user"} = Skills.get("temp-skill")

    assert :ok = Skills.set_status("temp-skill", "user", "disabled")
    assert Skills.get("temp-skill").status == "disabled"
    refute "temp-skill" in Enum.map(Skills.active(), & &1.name)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: temp-skill\ndescription: Temporary, edited.\n---\n\nnew body\n"
    )

    Registry.rescan()
    assert %Skill{version: 2, status: "disabled", body: "new body\n"} = Skills.get("temp-skill")
    assert {:error, :not_found} = Skills.set_status("nope", "user", "active")
    assert {:error, {:status, "sleepy"}} = Skills.set_status("temp-skill", "user", "sleepy")

    File.rm_rf!(skill_dir)
    Registry.rescan()
    assert Skills.get("temp-skill") == nil
    assert Repo.get_by(Row, name: "temp-skill", source: "user") == nil
  end

  test "a skill whose manifest does not match its files is refused and named in the errors", %{
    old: old
  } do
    dir = tmp_user_dir(old)
    File.cp_r!(Path.join(@fixtures, "mismatch/tampered"), Path.join(dir, "tampered"))
    Registry.rescan()
    assert Skills.get("tampered") == nil
    assert [%{source: "user", reason: {:manifest_mismatch, _}}] = Registry.errors()
  end

  # AC3: needs a watcher backend: inotifywait on Linux, or the polling fallback the registry
  # picks without it; either answers within the criterion's 2 s.
  @tag timeout: 20_000
  test "AC3: a SKILL.md edited on disk is in the registry within 2 s without a rescan", %{
    old: old
  } do
    dir = tmp_user_dir(old)
    write_skill!(dir, "watched", "Before.")
    Registry.rescan()
    assert Skills.get("watched").description == "Before."
    # inotifywait establishes its watches a moment after it starts and says nothing when it
    # has; an edit before that is missed (one run in three without a pause). And the polling
    # backend the registry picks where inotifywait is absent (the gate's runners, run
    # 35623752961) compares mtimes at one-second resolution: an edit inside the second the
    # file was written in is no change to it. So the edit waits a second and a bit.
    Process.sleep(1_100)

    File.write!(
      Path.join([dir, "watched", "SKILL.md"]),
      "---\nname: watched\ndescription: After.\n---\n\nafter\n"
    )

    started = System.monotonic_time(:millisecond)

    assert Enum.find_value(1..100, fn _ ->
             Process.sleep(20)

             if Skills.get("watched").description == "After.",
               do: System.monotonic_time(:millisecond) - started
           end)
           |> then(fn ms ->
             IO.puts("\nAC3: the edit was in the registry after #{ms} ms")
             ms
           end) <= 2_000
  end
end
