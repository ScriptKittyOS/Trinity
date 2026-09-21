# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.AlwaysOnTest do
  @moduledoc "Slice 030: the seed (AC1's first half), the scope chain (AC7's data half), the snapshot, the log, the budget and the consolidator (AC3)."
  use Trinity.DataCase, async: false

  alias Trinity.{Factory, Personas, Sessions}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Memory.{AlwaysOn, Budget, Consolidator, Entry}

  setup do
    persona = Factory.persona!()
    on_exit(fn -> Fake.clear() end)
    {:ok, persona: persona, pscope: AlwaysOn.persona_scope(persona.id)}
  end

  defp add!(persona, attrs, opts \\ [by: "test"]) do
    {:ok, e} =
      AlwaysOn.add(
        Map.merge(
          %{persona_id: persona.id, tier: "always_on", scope: AlwaysOn.persona_scope(persona.id)},
          attrs
        ),
        opts
      )

    e
  end

  test "AC1: a fresh database seeds the default persona from priv/personas/default/SOUL.md with the memory rule; an edited soul is kept" do
    Trinity.Repo.delete_all(from(p in Trinity.Sessions.Persona, where: p.name == "default"))
    persona = Sessions.default_persona()
    assert persona.soul == File.read!("priv/personas/default/SOUL.md")
    assert persona.soul =~ "# Trinity"
    assert persona.settings["permissions"]["memory"] == "allow"
    assert Personas.default().id == persona.id

    {:ok, edited} = Personas.update(persona, %{soul: "# Mine"})
    assert Sessions.default_persona().soul == "# Mine"
    assert Personas.soul(edited) == "# Mine"
    assert Personas.soul(%Trinity.Sessions.Persona{soul: nil}) == "You are Trinity."

    # A pre-030 row (no soul) is seeded on its next read, and an edited one is not touched.
    {:ok, _} = Personas.update(edited, %{soul: nil})
    assert Sessions.default_persona().soul =~ "# Trinity"
  end

  test "the snapshot: profile before always-on, keys sorted, deterministic, empty when nothing",
       %{persona: persona} do
    assert AlwaysOn.snapshot(persona.id, nil) == ""
    add!(persona, %{key: "editor", body: "prefers neovim"})
    add!(persona, %{tier: "profile", key: "name", body: "Ayla"})
    add!(persona, %{key: "city", body: "Lisbon"})
    add!(persona, %{tier: "profile", key: "language", body: "English"})
    snap = AlwaysOn.snapshot(persona.id, nil)

    assert snap ==
             "## About the person\n- language: English\n- name: Ayla\n\n## Always in mind\n- city: Lisbon\n- editor: prefers neovim"

    assert AlwaysOn.snapshot(persona.id, nil) == snap
  end

  test "AC7 (data): a session-scoped entry is absent from another session's chain; promoted, it is present",
       %{persona: persona, pscope: pscope} do
    a = Factory.session!(%{persona_id: persona.id})
    b = Factory.session!(%{persona_id: persona.id})

    entry =
      add!(persona, %{scope: AlwaysOn.session_scope(a.id), key: "draft", body: "only for A"},
        by: "test",
        session_id: a.id
      )

    assert AlwaysOn.snapshot(persona.id, a.id) =~ "draft: only for A"
    refute AlwaysOn.snapshot(persona.id, b.id) =~ "draft"
    assert AlwaysOn.chain(persona.id, b.id) == ["session:" <> b.id, pscope, "global"]

    {:ok, moved} = AlwaysOn.promote(entry, pscope, by: "test", session_id: a.id)
    assert moved.scope == pscope
    assert AlwaysOn.snapshot(persona.id, b.id) =~ "draft: only for A"

    assert [%{action: "promote", before: "session:" <> _, after: ^pscope}, %{action: "add"}] =
             AlwaysOn.changes(persona.id)
  end

  test "writes are logged with before and after; add refuses a duplicate key; keys are validated",
       %{persona: persona} do
    e = add!(persona, %{key: "editor", body: "vim"})
    {:ok, e2} = AlwaysOn.replace(e, "neovim", by: "ui")
    {:ok, _} = AlwaysOn.remove(e2, by: "ui")

    assert {:error, %Ecto.Changeset{}} =
             AlwaysOn.add(
               %{
                 persona_id: persona.id,
                 tier: "always_on",
                 scope: "persona:x",
                 key: "Bad Key!",
                 body: "x"
               },
               by: "test"
             )

    add!(persona, %{key: "again", body: "1"})

    assert {:error, :exists} =
             AlwaysOn.add(
               %{
                 persona_id: persona.id,
                 tier: "always_on",
                 scope: AlwaysOn.persona_scope(persona.id),
                 key: "again",
                 body: "2"
               },
               by: "test"
             )

    assert [
             %{action: "add", key: "again", by: "test"},
             %{action: "remove", key: "editor", before: "neovim", after: nil, by: "ui"},
             %{action: "replace", key: "editor", before: "vim", after: "neovim", by: "ui"},
             %{action: "add", key: "editor", before: nil, after: "vim", by: "test"}
           ] = AlwaysOn.changes(persona.id)
  end

  describe "AC3: the budget and the consolidator" do
    setup do
      old = Application.get_env(:trinity, :memory, [])
      Application.put_env(:trinity, :memory, Keyword.put(old, :budget_bytes, 200))
      on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
      :ok
    end

    test "over budget after a write, a proposal under budget is applied at once and every dropped key is in the log",
         %{persona: persona, pscope: pscope} do
      add!(persona, %{key: "a", body: String.duplicate("alpha ", 15)})
      add!(persona, %{key: "b", body: String.duplicate("beta ", 15)})
      assert Budget.status(persona.id).over? == false

      Fake.object(%{
        "entries" => [
          %{
            "tier" => "always_on",
            "scope" => pscope,
            "key" => "ab",
            "body" => "alpha and beta, merged"
          }
        ]
      })

      add!(persona, %{key: "c", body: String.duplicate("gamma ", 15)})

      status = Budget.status(persona.id)
      assert status.used <= status.budget

      assert Enum.map(AlwaysOn.all(persona.id), &{&1.key, &1.body}) == [
               {"ab", "alpha and beta, merged"}
             ]

      [proposal] = Trinity.Repo.all(Trinity.Memory.Proposal)
      assert proposal.status == "applied"
      assert proposal.bytes_before > proposal.budget and proposal.bytes_after <= proposal.budget
      logged = AlwaysOn.changes_of_proposal(proposal.id)

      assert Enum.sort(Enum.map(logged, &{&1.action, &1.key})) == [
               {"add", "ab"},
               {"remove", "a"},
               {"remove", "b"},
               {"remove", "c"}
             ]

      assert Enum.all?(logged, &(&1.by == "consolidator"))
    end

    test "a proposal still over budget is held pending and nothing changes; the owner can apply or reject it",
         %{persona: persona, pscope: pscope} do
      add!(persona, %{key: "a", body: String.duplicate("alpha ", 20)})

      Fake.object(%{
        "entries" => [
          %{
            "tier" => "always_on",
            "scope" => pscope,
            "key" => "a",
            "body" => String.duplicate("alpha ", 40)
          }
        ]
      })

      add!(persona, %{key: "b", body: String.duplicate("beta ", 20)})

      assert [%{status: "pending"} = proposal] = Consolidator.pending(persona.id)
      assert Enum.map(AlwaysOn.all(persona.id), & &1.key) == ["a", "b"]
      assert Budget.status(persona.id).over?

      {:ok, %{status: "rejected"}} = Consolidator.reject_proposal(proposal)
      assert Consolidator.pending(persona.id) == []
      assert Enum.map(AlwaysOn.all(persona.id), & &1.key) == ["a", "b"]

      # Run again with a proposal that fits: applied, and the rejected one stays rejected.
      Fake.object(%{
        "entries" => [
          %{"tier" => "always_on", "scope" => pscope, "key" => "ab", "body" => "short"}
        ]
      })

      assert {:applied, %{status: "applied"}} = Consolidator.run(persona.id, [])
      assert Enum.map(AlwaysOn.all(persona.id), & &1.key) == ["ab"]
      assert Consolidator.get(proposal.id).status == "rejected"
    end

    test "a pending proposal applied by the owner is logged under its id like an automatic one",
         %{persona: persona, pscope: pscope} do
      add!(persona, %{key: "a", body: String.duplicate("alpha ", 20)})

      Fake.object(%{
        "entries" => [
          %{
            "tier" => "always_on",
            "scope" => pscope,
            "key" => "a",
            "body" => String.duplicate("alpha ", 40)
          }
        ]
      })

      add!(persona, %{key: "b", body: String.duplicate("beta ", 20)})
      [proposal] = Consolidator.pending(persona.id)
      assert {:ok, %{status: "applied"}} = Consolidator.apply_proposal(proposal, by: "ui")
      assert Enum.map(AlwaysOn.all(persona.id), & &1.key) == ["a"]

      assert Enum.sort(Enum.map(AlwaysOn.changes_of_proposal(proposal.id), &{&1.action, &1.key})) ==
               [{"remove", "b"}, {"replace", "a"}]
    end

    test "a model that answers no entries leaves the tiers as they are, over budget, with no proposal",
         %{persona: persona} do
      Fake.object(%{"entries" => []})
      add!(persona, %{key: "a", body: String.duplicate("alpha ", 40)})
      assert Budget.status(persona.id).over?
      assert Trinity.Repo.all(Trinity.Memory.Proposal) == []
      assert length(AlwaysOn.all(persona.id)) == 1
    end
  end

  test "bytes count key and body" do
    assert Entry.bytes(%Entry{key: "ab", body: "cde"}) == 5

    assert Budget.bytes_of([%{"key" => "ab", "body" => "cde"}, %{"key" => "x", "body" => ""}]) ==
             6
  end
end
