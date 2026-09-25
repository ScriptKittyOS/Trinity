# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.LearnerTest do
  @moduledoc """
  Slice 042 AC1 and AC3: what the owner's decisions imply, and the limit on what may be implied.

  AC3 is the one that matters. A proposal must never imply a permission broader than the decisions it
  was drawn from, and unanimity is what makes that true by construction: eleven allows and one deny
  would propose permitting the case the owner refused.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Permissions.{Approval, Learner}
  alias Trinity.Repo

  defp decided!(tool, status, n) do
    session = Trinity.Factory.session!()

    for i <- 1..n do
      Repo.insert!(%Approval{
        session_id: session.id,
        tool: tool,
        args: %{"n" => i},
        risk: "write",
        fingerprint: "fp-#{tool}-#{i}-#{System.unique_integer([:positive])}",
        status: status,
        decision: if(status == "allowed", do: "once", else: "deny"),
        decided_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
    end
  end

  describe "AC1: a rule the decisions imply" do
    test "a tool decided the same way enough times is proposed, with the count it is drawn from" do
      decided!("fs_read", "allowed", 6)

      assert [%{tool: "fs_read", decision: "allow", count: 6} = p] = Learner.proposals()
      assert p.first_seen
      assert p.last_seen
    end

    test "below the threshold nothing is proposed, because a habit is not yet a rule" do
      decided!("fs_read", "allowed", 2)
      assert [] = Learner.proposals(threshold: 5)
    end

    test "a denial proposes a deny rule, not silence" do
      decided!("shell", "denied", 7)
      assert [%{tool: "shell", decision: "deny", count: 7}] = Learner.proposals()
    end

    test "a tool a rule already covers is not proposed, because proposing what is already true is noise" do
      decided!("fs_read", "allowed", 8)

      {:ok, rule} =
        Trinity.Permissions.put_rule(%{tool: "fs_read", pattern: "*", decision: "allow"})

      on_exit(fn -> Trinity.Permissions.revoke_rule(rule.id) end)

      assert [] = Learner.proposals()
    end

    test "proposals come strongest first, so the most-evidenced is read first" do
      decided!("fs_read", "allowed", 9)
      decided!("fs_list", "allowed", 6)

      assert [%{tool: "fs_read"}, %{tool: "fs_list"}] = Learner.proposals()
    end
  end

  describe "AC3: a proposal can never be broader than its evidence" do
    test "one dissent among many agreements proposes nothing at all" do
      decided!("fs_write", "allowed", 11)
      decided!("fs_write", "denied", 1)

      assert [] = Learner.proposals(),
             "eleven allows and one deny proposed a rule. That rule would permit the case the " <>
               "owner refused, which is the one thing a proposal may never do"
    end

    test "the dissent becomes a divergence to look at instead of being discarded" do
      decided!("fs_write", "allowed", 11)
      decided!("fs_write", "denied", 1)

      assert [%{tool: "fs_write", counts: counts, total: 12}] = Learner.divergences()
      assert counts["allowed"] == 11
      assert counts["denied"] == 1
    end

    test "a unanimous tool is not a divergence" do
      decided!("fs_read", "allowed", 6)
      assert [] = Learner.divergences()
    end

    test "pending approvals are not decisions and are not counted" do
      session = Trinity.Factory.session!()

      Repo.insert!(%Approval{
        session_id: session.id,
        tool: "fs_read",
        args: %{},
        risk: "read",
        fingerprint: "pending-1",
        status: "pending",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      decided!("fs_read", "allowed", 5)

      assert [%{count: 5}] = Learner.proposals(),
             "a pending approval was counted as a decision, so the learner would propose from " <>
               "questions nobody has answered"
    end
  end

  test "the threshold is configuration the code reads, not a constant in two places" do
    assert is_integer(Learner.threshold()) and Learner.threshold() > 0
  end
end
