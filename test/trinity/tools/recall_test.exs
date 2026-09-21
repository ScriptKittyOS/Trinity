# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.RecallTest do
  @moduledoc "Slice 032 AC6's automatic half: the `recall` tool through the runner in force, memories and messages fused, a read's receipts, the tier off named."
  use Trinity.DataCase, async: false

  alias Trinity.{Effects, Factory, Receipts, Sessions}
  alias Trinity.Memory.{AlwaysOn, Semantic}
  alias Trinity.Tools.Context

  setup do
    persona = Factory.persona!()
    old = Factory.session!(%{persona_id: persona.id, title: "Last week"})

    {:ok, _} =
      Sessions.append_message(old.id, %{
        role: "user",
        content: "near dog: what is my dog called? Rex"
      })

    {:ok, m} =
      Semantic.add(
        %{
          persona_id: persona.id,
          scope: AlwaysOn.persona_scope(persona.id),
          key: "dog",
          body: "#near:dog has a dog named Rex"
        },
        by: "test"
      )

    here = Factory.session!(%{persona_id: persona.id, title: "Now"})
    scope = Receipts.session_scope(here.id)
    on_exit(fn -> Receipts.stop_writer(scope) end)

    {:ok,
     ctx: %Context{session_id: here.id, caller: here.id, persona: persona},
     old: old,
     memory: m,
     scope: scope}
  end

  test "registered as a core read tool in the memory toolset, the catalog untouched" do
    assert {:ok, %{kind: :core, risk: :read, effect: :none}} = Trinity.Tools.lookup("recall")
    assert Trinity.Permissions.tier("recall") == :read
    refute "recall" in Trinity.Tools.Catalog.names()
    assert "recall" in Application.get_env(:trinity, :tools)[:toolsets][:memory]
  end

  test "fused hits: the memory by meaning and the message by its words, as untrusted text, with a query receipt",
       %{ctx: ctx, old: old, scope: scope} do
    call = %{
      id: "c1",
      name: "recall",
      args: %{"query" => "#near:dog what is my dog called", "k" => 5}
    }

    assert {:ok, %{content: text, meta: meta}, _} = Effects.Runner.run(call, ctx)
    assert text =~ "memory dog · 20"
    assert text =~ "has a dog named Rex"
    assert text =~ "Last week (#{old.id}) · 20"
    assert text =~ "user: [near] [dog]"
    refute text =~ "unavailable"
    assert meta["hits"] == 2 and meta["memory_hits"] == 1 and meta["semantic"] == true
    assert Enum.map(Receipts.list(scope), & &1.kind) == ["decision", "query"]

    assert {:ok, %{content: "Nothing recalled for \"zzz\"."}, _} =
             Effects.Runner.run(%{id: "c2", name: "recall", args: %{"query" => "zzz"}}, ctx)

    assert {:error, {:invalid_args, _}, _} =
             Effects.Runner.run(
               %{id: "c3", name: "recall", args: %{"query" => "x", "k" => 500}},
               ctx
             )
  end

  test "without a persona nothing is recalled; with the tier off the answer says so and carries the full-text half",
       %{ctx: ctx} do
    assert {:ok, %{content: "Nothing recalled for \"x\"."}, _} =
             Effects.Runner.run(%{id: "c4", name: "recall", args: %{"query" => "x"}}, %{
               ctx
               | persona: nil
             })

    old = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(old,
        embedder: :local,
        model_cache_dir: no_models()
      )
    )

    call = %{id: "c5", name: "recall", args: %{"query" => "#near:dog what is my dog called"}}
    assert {:ok, %{content: text, meta: meta}, _} = Effects.Runner.run(call, ctx)

    assert text =~
             "(semantic recall is unavailable: the local model is not downloaded; full-text hits only)\n"

    assert text =~ "user: [near] [dog]"
    refute text =~ "memory dog"
    assert meta["semantic"] == false and meta["memory_hits"] == 0
  end

  defp no_models do
    cache = Path.join(System.tmp_dir!(), "no-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(cache) end)
    cache
  end
end
