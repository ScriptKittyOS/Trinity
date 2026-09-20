# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.GateTest do
  @moduledoc """
  Slice 021: the layered policy in isolation and in order, the Gate's rows and broadcasts,
  AC6 (expiry) and AC7's auto half (every decision a row with decided_at).
  """
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval

  setup do
    row = Factory.session!()
    :ok = Permissions.subscribe(row.id)
    {:ok, id: row.id}
  end

  @args %{"path" => "/home/me/notes/a.md", "text" => "hi"}

  describe "the layers" do
    test "the default by tier: read allows, write asks, an unmapped name asks", %{id: id} do
      assert Permissions.decide(id, "echo", %{"text" => "x"}) == :allow
      assert Permissions.decide(id, "write_note", @args) == :ask
      assert Permissions.decide(id, "mcp:x:anything", %{}) == :ask
    end

    test "a global rule with a glob allows inside the pattern and not outside (AC4's core)", %{
      id: id
    } do
      {:ok, _} =
        Permissions.put_rule(%{
          tool: "write_note",
          pattern: "path=/home/me/notes/*.md",
          decision: "allow"
        })

      assert Permissions.decide(id, "write_note", @args) == :allow
      assert Permissions.decide(id, "write_note", %{"path" => "/etc/hosts"}) == :ask
    end

    test "a persona policy sits above global rules and below session grants", %{id: id} do
      persona = %{settings: %{"permissions" => %{"write_note" => "deny"}}}
      {:ok, _} = Permissions.put_rule(%{tool: "write_note", pattern: "*", decision: "allow"})
      assert Permissions.decide(id, "write_note", @args, persona: persona) == :deny
      fp = Permissions.fingerprint(id, "write_note", @args, nil)

      {:ok, _} =
        Permissions.put_rule(%{
          tool: "write_note",
          pattern: "fp:" <> fp,
          decision: "allow",
          scope: Permissions.scope(id)
        })

      assert Permissions.decide(id, "write_note", @args, persona: persona) == :allow
    end

    test "a session grant is bound to the fingerprint: other arguments ask, another session asks (AC3's core)",
         %{id: id} do
      fp = Permissions.fingerprint(id, "write_note", @args, nil)

      {:ok, _} =
        Permissions.put_rule(%{
          tool: "write_note",
          pattern: "fp:" <> fp,
          decision: "allow",
          scope: Permissions.scope(id)
        })

      assert Permissions.decide(id, "write_note", @args) == :allow
      assert Permissions.decide(id, "write_note", Map.put(@args, "text", "changed")) == :ask
      other = Factory.session!()
      assert Permissions.decide(other.id, "write_note", @args) == :ask
    end

    test "an expired session grant no longer allows", %{id: id} do
      fp = Permissions.fingerprint(id, "write_note", @args, nil)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {:ok, _} =
        Permissions.put_rule(%{
          tool: "write_note",
          pattern: "fp:" <> fp,
          decision: "allow",
          scope: Permissions.scope(id),
          expires_at: past
        })

      assert Permissions.decide(id, "write_note", @args) == :ask
    end
  end

  describe "the Gate" do
    test "a request is a row, then a broadcast on the session's topic and on all", %{id: id} do
      :ok = Permissions.subscribe(:all)
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)
      assert %Approval{status: "pending", risk: "write", fingerprint: fp} = a
      assert fp == Permissions.fingerprint(id, "write_note", @args, nil)
      assert_receive {:approval, :requested, %Approval{id: aid}}
      assert_receive {:approval, :requested, %Approval{id: ^aid}}
      assert aid == a.id
      assert [%Approval{id: ^aid}] = Permissions.pending(id)
    end

    test "once: the row is allowed with decided_at and decider, the fingerprint allows one execution, then asks again",
         %{id: id} do
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)

      assert {:ok,
              %Approval{
                status: "allowed",
                decision: "once",
                decided_by: "liveview",
                decided_at: %DateTime{}
              }} =
               Permissions.decide_request(a.id, :once)

      assert_receive {:approval, :decided, %Approval{id: aid, status: "allowed"}}
      assert aid == a.id
      assert Permissions.decide(id, "write_note", @args) == :allow
      assert Permissions.decide(id, "write_note", @args) == :ask
      assert Permissions.pending(id) == []
    end

    test "session: a grant row scoped to the session with an expiry; the second identical call allows",
         %{id: id} do
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)
      {:ok, _} = Permissions.decide_request(a.id, :session)
      [rule] = Permissions.list_rules(scope: Permissions.scope(id))
      assert rule.pattern == "fp:" <> a.fingerprint and rule.expires_at != nil
      assert Permissions.decide(id, "write_note", @args) == :allow
      assert Permissions.decide(id, "write_note", @args) == :allow
    end

    test "always: a global rule with the confirmed pattern; a call outside it still asks (AC4)",
         %{id: id} do
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)
      {:ok, _} = Permissions.decide_request(a.id, :always, pattern: "path=/home/me/notes/*.md")
      [rule] = Permissions.list_rules(scope: "global")
      assert rule.tool == "write_note" and rule.decision == "allow"
      assert Permissions.decide(id, "write_note", @args) == :allow
      assert Permissions.decide(id, "write_note", %{"path" => "/home/me/secrets/k"}) == :ask
      assert :ok = Permissions.revoke_rule(rule.id)
      assert Permissions.decide(id, "write_note", @args) == :ask
    end

    test "deny: the row is denied, the fingerprint is denied once, then asks again (AC5's core)",
         %{id: id} do
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)

      {:ok, %Approval{status: "denied", decision: "deny"}} =
        Permissions.decide_request(a.id, :deny)

      assert Permissions.decide(id, "write_note", @args) == :deny
      assert Permissions.decide(id, "write_note", @args) == :ask
    end

    test "a decided request cannot be decided twice; an unknown id is not found", %{id: id} do
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)
      {:ok, _} = Permissions.decide_request(a.id, :deny)
      assert {:error, {:already_decided, "denied"}} = Permissions.decide_request(a.id, :once)
      assert {:error, :not_found} = Permissions.decide_request(Trinity.UUID.generate(), :once)
    end

    test "AC6: an undecided request expires into a denial decided by expiry, within the configured timeout",
         %{id: id} do
      {:ok, a} = Permissions.request_approval(id, "write_note", @args)

      assert_receive {:approval, :decided,
                      %Approval{
                        id: aid,
                        status: "expired",
                        decision: "deny",
                        decided_by: "expiry"
                      }},
                     1_000 + 500

      assert aid == a.id
      assert %Approval{decided_at: %DateTime{}} = Permissions.get_approval(a.id)
      assert Permissions.decide(id, "write_note", @args) == :ask
    end

    test "AC7: every decision is a row with decided_at, listed newest first", %{id: id} do
      {:ok, a1} = Permissions.request_approval(id, "write_note", @args)
      {:ok, a2} = Permissions.request_approval(id, "write_note", %{"path" => "/b"})
      {:ok, _} = Permissions.decide_request(a1.id, :once)
      {:ok, _} = Permissions.decide_request(a2.id, :deny)
      rows = Permissions.list_approvals(session_id: id)
      assert Enum.map(rows, & &1.id) == [a2.id, a1.id]
      assert Enum.all?(rows, &(&1.decided_at != nil and &1.decided_by == "liveview"))
    end
  end
end
