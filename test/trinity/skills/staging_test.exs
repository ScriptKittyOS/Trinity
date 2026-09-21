# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.StagingTest do
  @moduledoc "Slice 041: AC1 staging without loading, AC2 approve a create, AC3 patch with diff, history and reject, AC5 the pending change survives a restart, AC8's swap refusals; the diff and the actions."
  use Trinity.DataCase, async: false

  alias Trinity.{Factory, Permissions, Receipts}
  alias Trinity.Skills
  alias Trinity.Skills.{Change, Diff, Manager, Promotion, Registry, Staging}

  @md "---\nname: NAME\ndescription: A skill the agent proposed. Use when a test needs one.\nmetadata:\n  category: testing\n---\n\n# NAME\n\nStep one.\nStep two.\n"

  setup do
    old = Application.get_env(:trinity, :skills, [])
    user = Path.join(System.tmp_dir!(), "skills-user-#{System.unique_integer([:positive])}")
    pending = Path.join(System.tmp_dir!(), "skills-pending-#{System.unique_integer([:positive])}")
    File.mkdir_p!(user)

    Application.put_env(
      :trinity,
      :skills,
      Keyword.merge(old, user_dir: user, pending_dir: pending)
    )

    on_exit(fn ->
      Application.put_env(:trinity, :skills, old)
      File.rm_rf(user)
      File.rm_rf(pending)
      Receipts.stop_writer(Promotion.scope())
      Registry.rescan()
    end)

    Registry.rescan()
    {:ok, user: user, pending: pending, md: String.replace(@md, "NAME", "proposed-skill")}
  end

  test "AC1: a create is a row and staged files under the pending root, and the registry does not list it",
       %{pending: pending, md: md} do
    assert {:ok, %Change{} = c} =
             Staging.propose(
               "create",
               "proposed-skill",
               %{"skill_md" => md, "files" => %{"references/notes.md" => "notes\n"}},
               rationale: "the test asked",
               proposed_by: nil
             )

    assert c.status == "pending" and c.action == "create" and c.severity == "none"
    assert c.rationale == "the test asked"
    assert String.starts_with?(c.change_dir, pending)
    assert File.read!(Path.join(c.change_dir, "SKILL.md")) == md
    assert File.read!(Path.join(c.change_dir, "references/notes.md")) == "notes\n"
    assert c.digest == Staging.digest(c.change_dir)
    assert c.diff =~ "+++ proposed-skill/SKILL.md"
    assert c.diff =~ "+Step one."
    refute c.destructive

    assert Skills.get("proposed-skill") == nil
    Registry.rescan()
    assert Skills.get("proposed-skill") == nil
    assert [%Change{id: id}] = Staging.list()
    assert id == c.id
  end

  test "AC2: approve a create: the files land in the user root, the registry lists it at version 1, the receipt carries the digest and the approval",
       %{user: user, md: md} do
    {:ok, c} = Staging.propose("create", "proposed-skill", %{"skill_md" => md}, [])

    assert {:ok, %Change{status: "applied", applied_version: 1, decided_by: "ui"} = applied} =
             Manager.approve(c, by: "ui", comment: "fine")

    assert File.read!(Path.join([user, "proposed-skill", "SKILL.md"])) == md
    refute File.exists?(c.change_dir)
    assert %{source: "user", version: 1, status: "active"} = Skills.get("proposed-skill")
    assert Staging.get(applied.id).comment == "fine"

    approval = Permissions.get_approval(applied.approval_id)
    assert approval.tool == "skill_apply" and approval.status == "allowed"
    assert approval.args["change_id"] == c.id and approval.args["digest"] == c.digest

    [receipt] = Receipts.list(Promotion.scope(), kind: "effect")
    assert receipt.receipt_hash == applied.receipt_hash
    assert receipt.subject["digest"] == c.digest and receipt.subject["approval_id"] == approval.id
    assert receipt.subject_ref == "skill:proposed-skill@#{c.digest}"
    assert Staging.list() == []
  end

  test "AC3: a patch shows its diff; approved it is version 2 with version 1 in .history; a rejected one changes nothing",
       %{user: user, md: md} do
    {:ok, c} = Staging.propose("create", "proposed-skill", %{"skill_md" => md}, [])
    {:ok, _} = Manager.approve(c, by: "ui")

    diff =
      Diff.unified(
        md,
        String.replace(md, "Step two.", "Step two, carefully."),
        "proposed-skill/SKILL.md",
        "proposed-skill/SKILL.md"
      )

    assert {:ok, patch} =
             Staging.propose("patch", "proposed-skill", %{"diff" => diff}, rationale: "more care")

    assert patch.diff =~ "-Step two.\n+Step two, carefully."
    refute patch.destructive

    {:ok, rejected} = Manager.reject(patch, by: "ui", comment: "no")
    assert rejected.status == "rejected" and rejected.comment == "no"
    refute File.exists?(patch.change_dir)
    assert File.read!(Path.join([user, "proposed-skill", "SKILL.md"])) == md
    assert Skills.get("proposed-skill").version == 1

    {:ok, patch2} = Staging.propose("patch", "proposed-skill", %{"diff" => diff}, [])
    {:ok, applied} = Manager.approve(patch2, by: "ui")
    assert applied.applied_version == 2
    assert File.read!(Path.join([user, "proposed-skill", "SKILL.md"])) =~ "Step two, carefully."
    assert File.read!(Path.join([user, ".history", "proposed-skill", "v1", "SKILL.md"])) == md
    assert Skills.get("proposed-skill").version == 2

    # A whole-body replace is destructive and says so; a delete too.
    {:ok, replace} = Staging.propose("patch", "proposed-skill", %{"skill_md" => md}, [])
    assert replace.destructive
    {:ok, del} = Staging.propose("delete", "proposed-skill", %{}, [])
    assert del.destructive and del.diff =~ "(deleted)"
    {:ok, _} = Manager.reject(replace, [])
    {:ok, gone} = Manager.approve(del, by: "ui")
    assert gone.status == "applied" and gone.applied_version == nil
    refute File.dir?(Path.join(user, "proposed-skill"))
    assert File.dir?(Path.join([user, ".history", "proposed-skill", "v2"]))
    assert Skills.get("proposed-skill") == nil
  end

  test "write_file and remove_file; a bad path, a bad diff, an invalid result and an unknown skill are refused by name",
       %{md: md} do
    {:ok, c} = Staging.propose("create", "proposed-skill", %{"skill_md" => md}, [])
    {:ok, _} = Manager.approve(c, by: "ui")

    {:ok, w} =
      Staging.propose(
        "write_file",
        "proposed-skill",
        %{"path" => "references/more.md", "content" => "more\n"},
        []
      )

    assert w.diff =~ "+++ proposed-skill/references/more.md"
    refute w.destructive
    {:ok, _} = Manager.approve(w, by: "ui")

    {:ok, w2} =
      Staging.propose(
        "write_file",
        "proposed-skill",
        %{"path" => "references/more.md", "content" => "changed\n"},
        []
      )

    assert w2.destructive

    {:ok, r} =
      Staging.propose("remove_file", "proposed-skill", %{"path" => "references/more.md"}, [])

    assert r.diff =~ "-more"

    assert {:error, {:path, "../x"}} =
             Staging.propose(
               "write_file",
               "proposed-skill",
               %{"path" => "../x", "content" => "y"},
               []
             )

    assert {:error, {:args, _}} =
             Staging.propose("remove_file", "proposed-skill", %{"path" => "SKILL.md"}, [])

    assert {:error, {:no_such_file, "nope"}} =
             Staging.propose("remove_file", "proposed-skill", %{"path" => "nope"}, [])

    assert {:error, {:diff, _}} =
             Staging.propose("patch", "proposed-skill", %{"diff" => "-not there\n+x"}, [])

    assert {:error, {:invalid_skill, {:name, _}}} =
             Staging.propose("create", "other-skill", %{"skill_md" => md}, [])

    assert {:error, {:no_such_skill, "ghost"}} =
             Staging.propose("patch", "ghost", %{"skill_md" => md}, [])

    # A pending write_file for the skill exists here; a create is refused for the skill on
    # disk regardless, and for a name with a pending create (manage_tools_test).
    assert {:error, {:exists, "proposed-skill"}} =
             Staging.propose("create", "proposed-skill", %{"skill_md" => md}, [])

    assert {:error, {:name, _}} = Staging.propose("create", "Bad Name", %{"skill_md" => md}, [])
  end

  test "AC5: the registry and the gate restarted between staging and approval: the change and its files survive and it is still approvable",
       %{md: md} do
    {:ok, c} = Staging.propose("create", "proposed-skill", %{"skill_md" => md}, [])

    for child <- [Trinity.Skills.Registry, Trinity.Permissions.Gate] do
      :ok = Supervisor.terminate_child(Trinity.Supervisor, child)
      {:ok, _} = Supervisor.restart_child(Trinity.Supervisor, child)
    end

    assert %Change{status: "pending"} = again = Staging.get(c.id)
    assert File.exists?(Path.join(again.change_dir, "SKILL.md"))
    assert {:ok, %Change{status: "applied"}} = Manager.approve(again, by: "ui")
    assert Skills.get("proposed-skill").version == 1
  end

  test "AC8: swap/3 refuses without an approval, with a pending, denied, other-tool or other-change approval, and when the staged files changed",
       %{md: md} do
    {:ok, c} = Staging.propose("create", "proposed-skill", %{"skill_md" => md}, [])
    session = Factory.session!()
    assert {:error, :approval_required} = Promotion.swap(c, nil, "ui")
    assert {:error, {:no_such_approval, _}} = Promotion.swap(c, Ecto.UUID.generate(), "ui")

    {:ok, pending} =
      Permissions.request_approval(session.id, "skill_apply", %{
        "change_id" => c.id,
        "digest" => c.digest
      })

    assert {:error, {:approval_not_allowed, "pending"}} = Promotion.swap(c, pending.id, "ui")
    {:ok, _} = Permissions.decide_request(pending.id, :deny, by: "ui")
    assert {:error, {:approval_not_allowed, "denied"}} = Promotion.swap(c, pending.id, "ui")

    {:ok, other} = Permissions.request_approval(session.id, "fs_write", %{"path" => "x"})
    {:ok, _} = Permissions.decide_request(other.id, :once, by: "ui")
    assert {:error, {:approval_for_another_tool, "fs_write"}} = Promotion.swap(c, other.id, "ui")

    {:ok, wrong} =
      Permissions.request_approval(session.id, "skill_apply", %{
        "change_id" => Ecto.UUID.generate(),
        "digest" => c.digest
      })

    {:ok, _} = Permissions.decide_request(wrong.id, :once, by: "ui")
    assert {:error, {:approval_for_another_change, _}} = Promotion.swap(c, wrong.id, "ui")

    {:ok, right} =
      Permissions.request_approval(session.id, "skill_apply", %{
        "change_id" => c.id,
        "digest" => c.digest
      })

    {:ok, _} = Permissions.decide_request(right.id, :once, by: "ui")
    File.write!(Path.join(c.change_dir, "SKILL.md"), md <> "\ntampered\n")
    assert {:error, :staged_files_changed} = Promotion.swap(c, right.id, "ui")
    File.write!(Path.join(c.change_dir, "SKILL.md"), md)
    assert {:ok, %Change{status: "applied"}} = Promotion.swap(c, right.id, "ui")
    assert {:error, {:not_pending, "applied"}} = Promotion.swap(Staging.get(c.id), right.id, "ui")
    on_exit(fn -> Receipts.stop_writer(Receipts.session_scope(session.id)) end)
  end

  test "the diff: equal texts are empty; an edit shows context, removal and addition; a patch replays it" do
    assert Diff.unified("a\nb\n", "a\nb\n") == ""
    d = Diff.unified("a\nb\nc\n", "a\nB\nc\nd\n", "x", "x")
    assert d == "--- x\n+++ x\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n c\n+d\n "

    assert Diff.lcs_diff(["a", "b"], ["b", "a"]) in [
             [del: "a", eq: "b", add: "a"],
             [add: "b", eq: "a", del: "b"]
           ]

    refute Diff.text?(<<0, 255, 1>>)
    refute Diff.text?(String.duplicate("x", Diff.max_bytes() + 1))
  end
end
