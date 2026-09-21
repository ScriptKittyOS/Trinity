# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.PromptTiersTest do
  @moduledoc "Slice 030: the prompt's tiers, the frozen snapshot, the truncation receipt, AC1's prompt half and AC4."
  use Trinity.SessionCase

  alias Trinity.{Factory, Receipts, Sessions}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Memory.AlwaysOn
  alias Trinity.Sessions.{Prompt, Session}

  @now ~U[2026-09-21 09:00:00Z]

  test "the system prompt is stable (soul, tool guidance), then volatile (memory, time, title); the context tier is empty until 040" do
    persona = Factory.persona!(%{soul: "# Me\nBe brief."})
    session = Factory.session!(%{persona_id: persona.id, title: "Trip"})

    {request, []} =
      Prompt.build_with_report(session, persona, [], [],
        memory: "## Always in mind\n- editor: neovim",
        now: @now
      )

    assert request.system ==
             "# Me\nBe brief.\n\n" <>
               Prompt.untrusted_rule() <>
               "\n\n## Always in mind\n- editor: neovim\n\nThe time now is 2026-09-21T09:00:00Z (UTC). This conversation is titled \"Trip\"."

    {with_skills, []} =
      Prompt.build_with_report(session, persona, [], [],
        memory: "",
        now: @now,
        skills: "## Skills\n- none"
      )

    assert with_skills.system =~ ~r/Be brief\.\n\n.*\n\n## Skills\n- none\n\nThe time now is/s
    assert Prompt.budgets() == [stable: 800, context: 300, volatile: 2_800]
  end

  test "a tier over its budget is cut on a line boundary and reported with the tokens dropped" do
    old = Application.get_env(:trinity, :prompt_budgets, [])
    Application.put_env(:trinity, :prompt_budgets, volatile: 20)
    on_exit(fn -> Application.put_env(:trinity, :prompt_budgets, old) end)
    persona = Factory.persona!()
    session = Factory.session!(%{persona_id: persona.id})
    memory = Enum.map_join(1..30, "\n", &"- k#{&1}: #{String.duplicate("x", 20)}")

    {request, [%{tier: :volatile, dropped_tokens: dropped}]} =
      Prompt.build_with_report(session, persona, [], [], memory: memory, now: @now)

    assert dropped > 100
    assert request.system =~ "[cut at the tier's budget]"
    refute request.system =~ "k30"
    assert request.system =~ "test soul"
  end

  test "AC1 (prompt half): a session of the default persona opens its system prompt with the seeded soul" do
    Trinity.Repo.delete_all(from(p in Trinity.Sessions.Persona, where: p.name == "default"))
    persona = Sessions.default_persona()
    session = Factory.session!(%{persona_id: persona.id})
    {request, []} = Prompt.build_with_report(session, persona, [], [], now: @now)
    assert String.starts_with?(request.system, "# Trinity\n\nYou are Trinity, a personal agent")
    assert request.system =~ Prompt.untrusted_rule()
  end

  test "the snapshot is frozen at session start: an entry added mid-session is not in the next turn's prompt until refresh; a truncation writes its receipt" do
    persona = Factory.persona!()
    row = Factory.session!(%{persona_id: persona.id})
    scope = Receipts.session_scope(row.id)
    on_exit(fn -> Receipts.stop_writer(scope) end)

    {:ok, _} =
      AlwaysOn.add(
        %{
          persona_id: persona.id,
          tier: "always_on",
          scope: AlwaysOn.persona_scope(persona.id),
          key: "before",
          body: "known at start"
        }, by: "test")

    Fake.scripts([script_deltas(1, "ok "), script_deltas(1, "ok "), script_deltas(1, "ok ")])
    {:ok, pid} = start_drained(row.id)
    {:ok, _} = Session.send_user_message(pid, "one")
    _ = collect(row.id, &match?({:state, :idle}, &1))
    assert Fake.last_request().system =~ "- before: known at start"

    {:ok, _} =
      AlwaysOn.add(
        %{
          persona_id: persona.id,
          tier: "always_on",
          scope: AlwaysOn.persona_scope(persona.id),
          key: "later",
          body: "added mid-session"
        }, by: "test")

    {:ok, _} = Session.send_user_message(pid, "two")
    _ = collect(row.id, &match?({:state, :idle}, &1))
    refute Fake.last_request().system =~ "later"

    assert {:ok, snapshot} = Session.refresh_memory(pid)
    assert snapshot =~ "- later: added mid-session"
    {:ok, _} = Session.send_user_message(pid, "three")
    _ = collect(row.id, &match?({:state, :idle}, &1))
    assert Fake.last_request().system =~ "- later: added mid-session"

    assert Receipts.list(scope, kind: "query") |> Enum.reject(&(&1.subject["prompt_tier"] == nil)) ==
             []

    # A budget the snapshot exceeds: the next turn's prompt is cut and the cut is receipted.
    old = Application.get_env(:trinity, :prompt_budgets, [])
    Application.put_env(:trinity, :prompt_budgets, volatile: 10)
    on_exit(fn -> Application.put_env(:trinity, :prompt_budgets, old) end)
    Fake.scripts([script_deltas(1, "ok ")])
    {:ok, _} = Session.send_user_message(pid, "four")
    _ = collect(row.id, &match?({:state, :idle}, &1))

    [receipt] =
      Receipts.list(scope, kind: "query")
      |> Enum.filter(&(&1.subject["prompt_tier"] == "volatile"))

    assert JSON.decode!(receipt.signed_payload)["decision"]["dropped_tokens"] > 0
    assert receipt.subject_ref == "prompt:#{row.id}:volatile"
  end

  test "AC4: two personas with different souls run concurrent sessions and their prompts differ" do
    a = Factory.persona!(%{soul: "# Alpha\nYou are the alpha persona."})
    b = Factory.persona!(%{soul: "# Beta\nYou are the beta persona."})

    {:ok, _} =
      AlwaysOn.add(
        %{
          persona_id: b.id,
          tier: "profile",
          scope: AlwaysOn.persona_scope(b.id),
          key: "name",
          body: "Bea"
        }, by: "test")

    sa = Factory.session!(%{persona_id: a.id})
    sb = Factory.session!(%{persona_id: b.id})

    on_exit(fn ->
      Receipts.stop_writer(Receipts.session_scope(sa.id))
      Receipts.stop_writer(Receipts.session_scope(sb.id))
    end)

    Fake.scripts([script_deltas(1, "a "), script_deltas(1, "b ")])
    {:ok, pa} = start_drained(sa.id)
    {:ok, pb} = start_drained(sb.id)
    assert Process.alive?(pa) and Process.alive?(pb)

    {:ok, _} = Session.send_user_message(pa, "hi")
    _ = collect(sa.id, &match?({:state, :idle}, &1))
    alpha = Fake.last_request().system
    {:ok, _} = Session.send_user_message(pb, "hi")
    _ = collect(sb.id, &match?({:state, :idle}, &1))
    beta = Fake.last_request().system

    assert String.starts_with?(alpha, "# Alpha\n")
    assert String.starts_with?(beta, "# Beta\n")
    refute alpha =~ "Bea"
    assert beta =~ "## About the person\n- name: Bea"
  end
end
