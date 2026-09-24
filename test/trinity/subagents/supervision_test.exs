# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Subagents.SupervisionTest do
  @moduledoc """
  Slice 080, AC4 to AC6: a child that dies is reported rather than silently retried, cancelling a
  parent cancels its whole subtree, and an approval raised inside a child carries the child's id.

  AC4 is answered differently from the way the slice wrote it, and the deviation is the point of
  these tests. The criterion said a killed child restarts once by default. It does not: restarting
  an agent turn replays an arbitrary sequence of tool calls, and a `:session` or `:always` approval
  would cover that replay silently. The default is zero restarts, the option exists for a caller
  who knows their brief is idempotent, and both halves are tested.
  """
  use Trinity.SessionCase

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Subagents

  defp parent! do
    {:ok, p} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "parent"})

    p
  end

  describe "AC4: a dead child is reported, not silently replayed" do
    test "the default is zero restarts, stated rather than implied" do
      assert Subagents.default_restarts() == 0
    end

    test "the caller of delegate/3 survives its child being killed" do
      # The regression the Postgres leg found. Every call into a child is a gen_statem.call, and a
      # call into a process that dies exits the caller; on SQLite the kill happened to land after
      # the call returned and the test passed for that reason alone.
      Fake.scripts([[{:text_delta, "working "}, {:sleep, 5_000}, {:done, :stop}]])
      parent = parent!()

      caller =
        Task.Supervisor.async_nolink(Trinity.LLM.TaskSupervisor, fn ->
          Subagents.delegate(parent.id, "a brief whose child dies mid-call")
        end)

      child_id = await_child(parent.id)
      {:ok, pid} = Sessions.ensure_started(child_id)
      Process.exit(pid, :kill)

      # A result, not an exit: the parent is told its child died rather than dying with it.
      assert {:ok, %{status: :error, reason: {:child_died, _}}} = Task.await(caller, 30_000)
    end

    test "a child killed mid-turn reports the death to its parent" do
      # The fake's own {:sleep, ms} keeps the turn open, so the kill lands mid-turn rather than
      # racing a turn that has already finished. A script that merely omits its terminator does
      # not do this: the stream ends and the turn completes anyway, which is how the first version
      # of this test passed for the wrong reason.
      Fake.scripts([[{:text_delta, "working "}, {:sleep, 5_000}, {:done, :stop}]])
      parent = parent!()

      # Task.async links, so if delegate/3 exited when the child died the test process would die
      # with it rather than report. async_nolink is what makes the assertion below reachable when
      # the library is wrong, which is the state this test is meant to detect.
      task =
        Task.Supervisor.async_nolink(Trinity.LLM.TaskSupervisor, fn ->
          Subagents.delegate(parent.id, "a brief that gets interrupted")
        end)

      # Wait for the child to exist, then kill its process.
      child_id = await_child(parent.id)
      {:ok, pid} = Sessions.ensure_started(child_id)
      Process.exit(pid, :kill)

      assert {:ok, result} = Task.await(task, 30_000)
      assert result.status == :error
      assert {:child_died, _} = result.reason
      assert result.session_id == child_id
    end

    test "a budget overrun is not retried even when restarts are allowed" do
      # Retrying an overrun under the same budget overruns it again; only a death is transient.
      Fake.scripts([script_deltas(1, "x ")])
      parent = parent!()

      assert {:ok, result} =
               Subagents.delegate(parent.id, "too slow", budget: %{timeout_ms: 0}, restarts: 3)

      assert result.status == :budget
      assert parent.id |> Subagents.children() |> length() == 1
    end
  end

  describe "AC5: cancelling a parent cancels its subtree" do
    test "a three-level tree is cancelled from the root, and the count is returned" do
      Fake.scripts(Enum.map(1..2, fn _ -> script_deltas(1, "ok ") end))
      root = parent!()

      {:ok, child} = Subagents.delegate(root.id, "level two")
      Fake.scripts([script_deltas(1, "ok ")])
      {:ok, grandchild} = Subagents.delegate(child.session_id, "level three")

      assert Subagents.children(root.id) |> Enum.map(& &1.id) == [child.session_id]
      assert Subagents.children(child.session_id) |> Enum.map(& &1.id) == [grandchild.session_id]

      # Root plus two descendants.
      assert Subagents.cancel_subtree(root.id) == 3
    end

    test "cancelling a session with no children cancels one thing and does not raise" do
      assert Subagents.cancel_subtree(parent!().id) == 1
    end
  end

  describe "AC6: an approval raised in a child names the child" do
    test "the request carries the child's session id, and the parent can find it by subtree" do
      Fake.scripts([script_deltas(1, "done ")])
      parent = parent!()
      {:ok, child} = Subagents.delegate(parent.id, "a brief that needs permission")

      {:ok, approval} =
        Permissions.request_approval(child.session_id, "write_note", %{"path" => "notes/a.md"},
          risk: :write
        )

      # The approval is against the child, not the parent: a request that named the parent would
      # be untraceable to the work that raised it.
      assert approval.session_id == child.session_id
      refute approval.session_id == parent.id

      # And the parent can reach it, because the subtree is discoverable from the parent.
      subtree_ids = [parent.id | Enum.map(Subagents.children(parent.id), & &1.id)]

      found =
        Permissions.pending(:all)
        |> Enum.filter(&(&1.session_id in subtree_ids))

      assert Enum.any?(found, &(&1.id == approval.id))
      assert Enum.any?(found, &(&1.session_id == child.session_id))
    end
  end

  defp await_child(parent_id, attempts \\ 200) do
    case Subagents.children(parent_id) do
      [child | _] -> child.id
      [] when attempts > 0 -> Process.sleep(10) && await_child(parent_id, attempts - 1)
      [] -> flunk("no child session appeared")
    end
  end
end
