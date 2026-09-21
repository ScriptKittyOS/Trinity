# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.MemoryTest do
  @moduledoc "Slice 030 AC2, AC6 and AC7 through the `memory` tool and the runner in force."
  use Trinity.DataCase, async: false

  alias Trinity.{Effects, Factory, Receipts}
  alias Trinity.Memory.AlwaysOn
  alias Trinity.Tools.Context

  setup do
    persona = Factory.persona!(%{settings: %{"permissions" => %{"memory" => "allow"}}})
    session = Factory.session!(%{persona_id: persona.id})
    ctx = %Context{session_id: session.id, caller: session.id, persona: persona}
    scope = Receipts.session_scope(session.id)
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, persona: persona, session: session, ctx: ctx, scope: scope}
  end

  defp call(ctx, id, args), do: Effects.Runner.run(%{id: id, name: "memory", args: args}, ctx)

  test "registered as a core write tool with the artifact effect, in the memory toolset" do
    assert {:ok, %{kind: :core, risk: :write, effect: :artifact, toolsets: [:memory]}} =
             Trinity.Tools.lookup("memory")
  end

  test "AC2: memory.add(always_on, editor, prefers neovim) leaves a row, and the next session's snapshot carries it",
       %{ctx: ctx, persona: persona} do
    assert {:ok, %{content: "Kept always_on editor (persona)."}, _} =
             call(ctx, "c1", %{
               "action" => "add",
               "tier" => "always_on",
               "key" => "editor",
               "body" => "prefers neovim"
             })

    assert [%{tier: "always_on", key: "editor", body: "prefers neovim", scope: "persona:" <> _}] =
             AlwaysOn.all(persona.id)

    next = Factory.session!(%{persona_id: persona.id})
    assert AlwaysOn.snapshot(persona.id, next.id) == "## Always in mind\n- editor: prefers neovim"
    assert [%{action: "add", by: "tool", session_id: sid}] = AlwaysOn.changes(persona.id)
    assert sid == ctx.session_id
  end

  test "AC6: the write is allowed by the persona's rule without asking, and the decision receipt names the basis",
       %{ctx: ctx, scope: scope} do
    assert {:ok, _, _} = call(ctx, "c1", %{"action" => "add", "key" => "k", "body" => "v"})
    assert Trinity.Permissions.list_approvals(session_id: ctx.session_id) == []
    [decision | effects] = Receipts.list(scope)
    assert decision.kind == "decision"

    assert JSON.decode!(decision.signed_payload)["decision"] == %{
             "outcome" => "allow",
             "basis" => "persona",
             "reason" => nil
           }

    assert Enum.map(effects, &{&1.kind, &1.subject["phase"]}) == [
             {"effect", "admit"},
             {"effect", "done"}
           ]
  end

  test "without the persona rule a memory write asks, like any write", %{
    persona: persona,
    session: session
  } do
    {:ok, plain} = Trinity.Personas.update(persona, %{settings: %{}})
    ctx = %Context{session_id: session.id, caller: session.id, persona: plain}

    assert {:error, {:approval_required, _}, _} =
             call(ctx, "c1", %{"action" => "add", "key" => "k", "body" => "v"})
  end

  test "AC7: a session-scoped entry is invisible to another session until promoted; the promotion is an effect with receipts",
       %{ctx: ctx, persona: persona} do
    assert {:ok, %{content: "Kept always_on draft (session)."}, _} =
             call(ctx, "c1", %{
               "action" => "add",
               "key" => "draft",
               "body" => "only here",
               "scope" => "session"
             })

    assert {:ok, %{content: "[always_on] [session] draft: only here"}, _} =
             call(ctx, "c2", %{"action" => "list"})

    other = Factory.session!(%{persona_id: persona.id})
    other_ctx = %Context{session_id: other.id, caller: other.id, persona: persona}
    other_scope = Receipts.session_scope(other.id)
    on_exit(fn -> Receipts.stop_writer(other_scope) end)

    assert {:ok, %{content: "Nothing is kept yet."}, _} =
             call(other_ctx, "c1", %{"action" => "list"})

    assert {:error, {:not_found, "draft"}, _} =
             call(other_ctx, "c2", %{"action" => "remove", "key" => "draft"})

    assert {:ok, %{content: "Promoted always_on draft to persona."}, _} =
             call(ctx, "c3", %{"action" => "promote", "key" => "draft", "scope" => "persona"})

    assert {:ok, %{content: "[always_on] [persona] draft: only here"}, _} =
             call(other_ctx, "c3", %{"action" => "list"})

    promote =
      Receipts.list(Receipts.session_scope(ctx.session_id))
      |> Enum.filter(&(&1.subject["call_id"] == "c3"))

    assert Enum.map(promote, &{&1.kind, &1.subject["phase"]}) == [
             {"decision", nil},
             {"effect", "admit"},
             {"effect", "done"}
           ]

    assert [%{action: "promote", before: "session:" <> _, after: "persona:" <> _} | _] =
             AlwaysOn.changes(persona.id)
  end

  test "replace, remove, a duplicate key, a bad key, and an action without its arguments", %{
    ctx: ctx
  } do
    {:ok, _, _} = call(ctx, "c1", %{"action" => "add", "key" => "city", "body" => "Porto"})

    assert {:ok, %{content: "Replaced always_on city."}, _} =
             call(ctx, "c2", %{"action" => "replace", "key" => "city", "body" => "Lisbon"})

    assert {:error, {:exists, "city"}, _} =
             call(ctx, "c3", %{"action" => "add", "key" => "city", "body" => "x"})

    assert {:error, {:invalid, %{key: _}}, _} =
             call(ctx, "c4", %{"action" => "add", "key" => "Bad Key", "body" => "x"})

    assert {:error, {:missing_arguments, "replace"}, _} =
             call(ctx, "c5", %{"action" => "replace"})

    assert {:ok, %{content: "Removed always_on city."}, _} =
             call(ctx, "c6", %{"action" => "remove", "key" => "city"})

    assert {:error, {:not_found, "city"}, _} =
             call(ctx, "c7", %{"action" => "remove", "key" => "city"})
  end
end
