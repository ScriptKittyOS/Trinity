# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects.MembraneTest do
  @moduledoc """
  Slice 024: the membrane's refusals and receipts (AC3's first half, AC4, AC5), through the
  runner in force (`Trinity.Effects.Runner`) as the Session calls it, and through
  `Trinity.Effects.execute/2` directly where a mutation between decision and execution
  has to be planted.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Authority.Staged
  alias Trinity.Effects
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Receipts.{Alarm, KeyCustody}
  alias Trinity.Tools.Context

  @note_args %{"path" => "/home/me/notes/a.md", "text" => "hi"}

  setup do
    session = Trinity.Factory.session!()
    scope = Receipts.session_scope(session.id)
    ctx = %Context{session_id: session.id, caller: session.id, call_id: "c1"}
    # A global rule so write_note is allowed without an approval round-trip.
    {:ok, rule} = Permissions.put_rule(%{tool: "write_note", pattern: "*", decision: "allow"})

    on_exit(fn ->
      Permissions.revoke_rule(rule.id)
      Receipts.stop_writer(scope)
      Alarm.clear()
    end)

    {:ok, ctx: ctx, scope: scope}
  end

  defp kinds(scope),
    do:
      scope |> Receipts.list() |> Enum.map(&{&1.kind, &1.subject["call_id"], &1.subject["phase"]})

  test "AC3: every gate decision and every effect yields a receipt: a read gives decision and query; an effect gives decision, admit and done",
       %{ctx: ctx, scope: scope} do
    calls = [
      %{id: "c1", name: "echo", args: %{"text" => "hi"}},
      %{id: "c2", name: "write_note", args: @note_args}
    ]

    results = Effects.Runner.run_all(calls, ctx)

    assert [{_, {:ok, %{content: "hi"}, _}}, {_, {:ok, %{content: "wrote 2 bytes" <> _}, _}}] =
             results

    rows = Receipts.list(scope)

    assert Enum.sort(kinds(scope)) ==
             Enum.sort([
               {"decision", "c1", nil},
               {"query", "c1", nil},
               {"decision", "c2", nil},
               {"effect", "c2", "admit"},
               {"effect", "c2", "done"}
             ])

    admit = Enum.find(rows, &(&1.kind == "effect" and &1.subject["phase"] == "admit"))
    done = Enum.find(rows, &(&1.kind == "effect" and &1.subject["phase"] == "done"))
    assert admit.seq < done.seq
    assert admit.signature != nil and done.signature != nil
    assert admit.subject_ref == "effect:#{ctx.session_id}:c2"
    body = JSON.decode!(done.signed_payload)
    assert body["decision"]["ok"] == true

    assert body["fingerprint"] ==
             Permissions.fingerprint(ctx.session_id, "write_note", @note_args, nil)

    assert Enum.all?(rows, &(&1.meta["tool_definition_digest"] != nil or &1.kind == "effect"))
  end

  test "a denied call yields a decision receipt and nothing else; an asked call the same", %{
    ctx: ctx,
    scope: scope
  } do
    {:ok, deny} =
      Permissions.put_rule(%{tool: "write_note", pattern: "*", decision: "deny", scope: "global"})

    on_exit(fn -> Permissions.revoke_rule(deny.id) end)

    assert {:error, :denied, _} =
             Effects.Runner.run(%{id: "c9", name: "write_note", args: @note_args}, ctx)

    assert [{"decision", "c9", nil}] = kinds(scope)
    [row] = Receipts.list(scope)
    assert JSON.decode!(row.signed_payload)["decision"]["outcome"] == "deny"
  end

  test "AC4: arguments mutated after the decision are denied at execution with a receipt (M2 re-verify)",
       %{ctx: ctx, scope: scope} do
    fp = Permissions.fingerprint(ctx.session_id, "write_note", @note_args, nil)
    {:ok, entry} = Trinity.Tools.lookup("write_note")

    staged = %Staged{
      tool: "write_note",
      module: entry.module,
      effect: :artifact,
      args: Map.put(@note_args, "text", "something else"),
      call_id: "c4",
      session_id: ctx.session_id,
      scope: scope,
      cwd: nil,
      decision: :allow,
      fingerprint: fp
    }

    assert {:error, {:denied, {:fingerprint_mismatch, ^fp, derived}}} =
             Effects.execute(staged, ctx)

    assert derived == Permissions.fingerprint(ctx.session_id, "write_note", staged.args, nil)
    assert [{"effect", "c4", "denied"}] = kinds(scope)
    [row] = Receipts.list(scope)
    assert JSON.decode!(row.signed_payload)["decision"]["reason"] =~ "fingerprint_mismatch"

    # The same staged effect with the arguments the decision bound runs.
    assert {:ok, %{content: "wrote 2 bytes" <> _}} =
             Effects.execute(%{staged | args: @note_args, call_id: "c5"}, ctx)
  end

  test "the idempotency key: a second execution of the same session and call id is denied with a receipt",
       %{ctx: ctx, scope: scope} do
    call = %{id: "c6", name: "write_note", args: @note_args}
    assert {:ok, _, _} = Effects.Runner.run(call, ctx)
    assert {:error, {:denied, {:duplicate_effect, ref}}, _} = Effects.Runner.run(call, ctx)
    assert ref == "effect:#{ctx.session_id}:c6"

    assert Enum.filter(kinds(scope), &match?({"effect", "c6", _}, &1)) == [
             {"effect", "c6", "admit"},
             {"effect", "c6", "done"},
             {"effect", "c6", "denied"}
           ]
  end

  test "a :catalog tool absent from the catalog, or a decision other than allow, is denied before anything runs",
       %{ctx: ctx, scope: scope} do
    {:ok, entry} = Trinity.Tools.lookup("write_note")

    base = %Staged{
      tool: "write_note",
      module: entry.module,
      effect: :artifact,
      args: @note_args,
      call_id: "c7",
      session_id: ctx.session_id,
      scope: scope,
      decision: :allow,
      fingerprint: Permissions.fingerprint(ctx.session_id, "write_note", @note_args, nil)
    }

    assert {:error, {:denied, {:not_in_catalog, "write_note"}}} =
             Effects.execute(%{base | effect: :catalog}, ctx)

    assert {:error, {:denied, {:decision_not_allow, :ask}}} =
             Effects.execute(%{base | decision: :ask, call_id: "c8"}, ctx)

    assert {:error, {:denied, {:effect_not_admitted, :none}}} =
             Effects.execute(%{base | effect: :none, call_id: "c9"}, ctx)

    assert Enum.map(kinds(scope), &elem(&1, 2)) == ["denied", "denied", "denied"]
  end

  test "AC5: the signing key removed mid-run: the next effect is denied, the alarm sounds, no unsigned receipt row exists; a read is refused too, because its decision cannot be receipted",
       %{ctx: ctx, scope: scope} do
    %{key_path: path} = KeyCustody.selected()
    bytes = File.read!(path)
    on_exit(fn -> File.write!(path, bytes) end)
    Alarm.clear()

    assert {:ok, _, _} =
             Effects.Runner.run(%{id: "c10", name: "write_note", args: @note_args}, ctx)

    before = Receipts.count(scope)

    :telemetry.attach(
      "s024-membrane-alarm",
      Alarm.event(),
      fn _, _, meta, pid -> send(pid, {:alarm, meta.reason}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("s024-membrane-alarm") end)

    File.rm!(path)

    assert {:error, {:decision_not_receipted, {:signer_unavailable, :signer_unavailable}}, _} =
             Effects.Runner.run(%{id: "c11", name: "write_note", args: @note_args}, ctx)

    assert_receive {:alarm, :signer_unavailable}
    assert Alarm.set?()

    assert {:error, {:decision_not_receipted, _}, _} =
             Effects.Runner.run(%{id: "c12", name: "echo", args: %{"text" => "x"}}, ctx)

    assert Receipts.count(scope) == before

    assert Receipts.list(scope)
           |> Enum.filter(&(&1.kind != "query"))
           |> Enum.all?(&(&1.signature != nil))

    # A membrane call whose decision was receipted before the key went: denied at admission,
    # and the denial cannot be receipted either, which the error names.
    {:ok, entry} = Trinity.Tools.lookup("write_note")

    staged = %Staged{
      tool: "write_note",
      module: entry.module,
      effect: :artifact,
      args: @note_args,
      call_id: "c13",
      session_id: ctx.session_id,
      scope: scope,
      decision: :allow,
      fingerprint: Permissions.fingerprint(ctx.session_id, "write_note", @note_args, nil)
    }

    assert {:error, {:denied, {:signer_unavailable, _}, {:receipt_failed, _}}} =
             Effects.execute(staged, ctx)

    assert Receipts.count(scope) == before

    File.write!(path, bytes)

    assert {:ok, _, _} =
             Effects.Runner.run(%{id: "c14", name: "write_note", args: @note_args}, ctx)
  end

  test "Local: stage stamps, decide follows the gate, execute runs the tool or refuses a denial, receipt appends" do
    {:ok, entry} = Trinity.Tools.lookup("write_note")
    scope = "local:" <> Trinity.UUID.generate()
    on_exit(fn -> Receipts.stop_writer(scope) end)

    staged = %Staged{
      tool: "write_note",
      module: entry.module,
      effect: :artifact,
      args: @note_args,
      call_id: "x",
      session_id: nil,
      scope: scope,
      decision: :allow,
      fingerprint: nil
    }

    local = Trinity.Authority.Local
    assert {:ok, %Staged{staged_at: %DateTime{}}} = local.stage(staged, %Context{})
    assert {:ok, :allow, %{"by" => "gate"}} = local.decide(staged, :allow, %Context{})
    assert {:ok, :deny, %{"by" => "gate"}} = local.decide(staged, :deny, %Context{})
    assert {:ok, :deny, %{"reason" => "undecided"}} = local.decide(staged, :ask, %Context{})
    assert {:ok, %{content: "wrote 2 bytes" <> _}} = local.execute(staged, :allow, %Context{})
    assert {:error, :denied} = local.execute(staged, :deny, %Context{})

    assert {:ok, %Receipts.Receipt{kind: "cap"}} =
             local.receipt("cap", %{scope: scope, subject: %{"cap" => "iterations"}})
  end
end
