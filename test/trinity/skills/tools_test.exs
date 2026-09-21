# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.ToolsTest do
  @moduledoc "Slice 040, AC4: skills_list under the cap with 50 fixture skills, skill_view's body, skill_file's jail; the three through the runner in force as reads."
  use Trinity.DataCase, async: false

  alias Trinity.{Effects, Factory, Receipts}
  alias Trinity.Memory.Tokens
  alias Trinity.Skills.{Index, Registry}
  alias Trinity.Tools.Context

  setup do
    old = Application.get_env(:trinity, :skills, [])
    dir = Path.join(System.tmp_dir!(), "skills-user-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:trinity, :skills, Keyword.put(old, :user_dir, dir))

    on_exit(fn ->
      Application.put_env(:trinity, :skills, old)
      File.rm_rf(dir)
      Registry.rescan()
    end)

    session = Factory.session!()
    scope = Receipts.session_scope(session.id)
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, dir: dir, ctx: %Context{session_id: session.id, caller: session.id}, scope: scope}
  end

  defp fixture!(dir, name, opts) do
    skill = Path.join(dir, name)
    File.mkdir_p!(Path.join(skill, "references"))

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{opts[:description] || "Fixture #{name} does a thing. Use when a test says so."}\nmetadata:\n  category: #{opts[:category] || "fixtures"}\n---\n\n# #{name}\n\nThe body of #{name}.\n"
    )

    File.write!(Path.join([skill, "references", "notes.md"]), "notes for #{name}\n")
    skill
  end

  test "registered as core reads in the skills toolset, the catalog untouched" do
    for name <- ~w(skills_list skill_view skill_file) do
      assert {:ok, %{kind: :core, risk: :read, effect: :none}} = Trinity.Tools.lookup(name)
      assert Trinity.Permissions.tier(name) == :read
      refute name in Trinity.Tools.Catalog.names()
    end

    assert Application.get_env(:trinity, :tools)[:toolsets][:skills] ==
             ~w(skills_list skill_view skill_file skill_manage learn)
  end

  test "AC4: with 50 fixture skills the index stays under the cap and says it was cut; skill_view returns the body; skill_file reads a reference and refuses ../secrets",
       %{dir: dir, ctx: ctx, scope: scope} do
    for i <- 1..50,
        do:
          fixture!(dir, "fixture-#{String.pad_leading(to_string(i), 2, "0")}",
            category: "cat-#{rem(i, 5)}"
          )

    File.write!(Path.join(dir, "secrets"), "not for the model\n")
    Registry.rescan()
    assert length(Trinity.Skills.active()) >= 50

    assert {:ok, %{content: text, meta: meta}, _} =
             Effects.Runner.run(%{id: "c1", name: "skills_list", args: %{}}, ctx)

    assert meta["skills"] >= 50
    assert Tokens.estimate(text) <= Index.default_tokens()
    assert text =~ "## Skills"
    assert text =~ "cat-0:"
    refute text =~ "skills_list for the rest"

    assert {:ok, %{content: cut}, _} =
             Effects.Runner.run(
               %{id: "c1b", name: "skills_list", args: %{"limit_tokens" => 60}},
               ctx
             )

    assert Tokens.estimate(cut) <= 60 + 5
    assert cut =~ "## Skills"

    assert {:ok, %{content: by_cat, meta: %{"skills" => 10}}, _} =
             Effects.Runner.run(
               %{id: "c1c", name: "skills_list", args: %{"category" => "cat-3"}},
               ctx
             )

    assert by_cat =~ "fixture-03"
    refute by_cat =~ "fixture-01"

    assert {:ok, %{content: body, meta: vmeta}, _} =
             Effects.Runner.run(
               %{id: "c2", name: "skill_view", args: %{"name" => "fixture-07"}},
               ctx
             )

    assert body =~ "# fixture-07 (user)"
    assert body =~ "The body of fixture-07."
    assert body =~ "## Files\n- references/notes.md"
    assert vmeta["body_hash"] =~ ~r/^[0-9a-f]{64}$/

    assert {:ok, %{content: "notes for fixture-07\n", meta: %{"bytes" => 21}}, _} =
             Effects.Runner.run(
               %{
                 id: "c3",
                 name: "skill_file",
                 args: %{"name" => "fixture-07", "path" => "references/notes.md"}
               },
               ctx
             )

    for bad <- ["../secrets", "../../secrets", "/etc/passwd", "references/../../secrets"] do
      assert {:error, {:outside_skill, ^bad}, _} =
               Effects.Runner.run(
                 %{id: "c4", name: "skill_file", args: %{"name" => "fixture-07", "path" => bad}},
                 ctx
               ),
             bad
    end

    # A symlink out of the skill directory is resolved and refused too.
    File.ln_s!(Path.join(dir, "secrets"), Path.join([dir, "fixture-07", "references", "link"]))

    assert {:error, {:outside_skill, "references/link"}, _} =
             Effects.Runner.run(
               %{
                 id: "c5",
                 name: "skill_file",
                 args: %{"name" => "fixture-07", "path" => "references/link"}
               },
               ctx
             )

    assert {:error, {:no_such_file, "references/none.md"}, _} =
             Effects.Runner.run(
               %{
                 id: "c6",
                 name: "skill_file",
                 args: %{"name" => "fixture-07", "path" => "references/none.md"}
               },
               ctx
             )

    assert {:error, {:no_such_skill, "nope"}, _} =
             Effects.Runner.run(%{id: "c7", name: "skill_view", args: %{"name" => "nope"}}, ctx)

    # Reads: a decision and a query receipt per call, nothing else.
    kinds = Receipts.list(scope) |> Enum.map(& &1.kind) |> Enum.uniq()
    assert Enum.sort(kinds) == ["decision", "query"]

    # A disabled skill is not viewable through the tool either.
    :ok = Trinity.Skills.set_status("fixture-07", "user", "disabled")

    assert {:error, {:no_such_skill, "fixture-07"}, _} =
             Effects.Runner.run(
               %{id: "c8", name: "skill_view", args: %{"name" => "fixture-07"}},
               ctx
             )
  end

  test "the prompt's index: categories alone and the hint when the list does not fit; the whole list when it does",
       %{dir: dir} do
    for i <- 1..50,
        do:
          fixture!(dir, "fixture-#{String.pad_leading(to_string(i), 2, "0")}",
            category: "cat-#{rem(i, 5)}"
          )

    Registry.rescan()
    skills = Trinity.Skills.active()

    full = Index.render(skills, 100_000)
    assert Tokens.estimate(full) > 338
    refute full =~ "call `skills_list`"

    small = Index.render(skills, 40)
    assert small =~ "## Skills\ncategories: cat-0 (10), cat-1 (10)"
    assert small =~ "call `skills_list` for the rest"

    capped = Index.render(skills, 338)
    assert Tokens.estimate(capped) <= 338
    assert capped =~ "cat-0:\n- fixture-05"
    assert capped =~ "call `skills_list` for the rest"
    assert Index.render([], 338) == ""
  end
end
