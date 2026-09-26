# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.QueueTest do
  @moduledoc """
  Slice 026, AC1 and AC4: the outbound queue under a partition, and its bound.

  A partition is the case this exists for rather than an exception to it. With the adapter
  unreachable the machine keeps working, the queue grows, and nothing is acknowledged; when the
  link returns, every queued receipt is acknowledged in order. Past the bound the machine stops
  accepting effects instead of performing them unacknowledged.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.{Forwarder, Queue, QueueEntry}
  alias Trinity.Repo.Receipts, as: RRepo
  alias Trinity.TestAuthority

  setup do
    scope = "test:" <> Trinity.UUID.generate()
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, scope: scope}
  end

  defp decision(n),
    do: %{
      kind: "decision",
      subject: %{"n" => n},
      decision: %{"outcome" => "allow"},
      fingerprint: "ab" <> Integer.to_string(n)
    }

  # The same route `test/trinity/mcp/auth/embedded_test.exs` already uses: the selection is a
  # persistent_term written at boot, and a test that wants a different authority writes it back.
  @selection_key {Trinity.Authority.Selection, :selected}

  defp with_authority(module, fun) do
    old = :persistent_term.get(@selection_key, Trinity.Authority.Local)
    :persistent_term.put(@selection_key, module)

    try do
      fun.()
    after
      :persistent_term.put(@selection_key, old)
    end
  end

  defp with_bound(n, fun) do
    old = Application.get_env(:trinity, :receipts, [])
    Application.put_env(:trinity, :receipts, Keyword.put(old, :queue_bound, n))

    try do
      fun.()
    after
      Application.put_env(:trinity, :receipts, old)
    end
  end

  describe "AC1: with the adapter unreachable the queue grows; with it back, all are acked in order" do
    test "every receipt written is queued", %{scope: scope} do
      for n <- 1..5, do: {:ok, _} = Receipts.append(scope, decision(n))

      assert Queue.depth(scope) == 5

      entries = Queue.pending(scope, 100)
      assert Enum.map(entries, & &1.seq) == [1, 2, 3, 4, 5]

      hashes = scope |> Receipts.list() |> Enum.map(& &1.receipt_hash)
      assert Enum.map(entries, & &1.receipt_hash) == hashes
    end

    test "the queued envelope is the exported receipt byte for byte", %{scope: scope} do
      {:ok, row} = Receipts.append(scope, decision(1))
      [entry] = Queue.pending(scope, 10)

      assert entry.envelope == row |> Trinity.Receipts.Receipt.to_export() |> JSON.encode!(),
             "the envelope was rebuilt rather than stored. The far side verifies a signature over " <>
               "these bytes offline, so a queue that reconstructs them can break verification " <>
               "without anything here failing."
    end

    test "effects proceed and nothing is acknowledged while the adapter is unreachable", %{
      scope: scope
    } do
      with_authority(TestAuthority.Unreachable, fn ->
        for n <- 1..4, do: {:ok, _} = Receipts.append(scope, decision(n))

        assert %{acked: 0, failed: failed} = Forwarder.drain(scope)
        assert failed > 0

        assert Queue.depth(scope) == 4, "an unreachable adapter acknowledged something"
      end)
    end

    test "a failed offer records the attempt and the reason, and drops nothing", %{scope: scope} do
      with_authority(TestAuthority.Unreachable, fn ->
        {:ok, _} = Receipts.append(scope, decision(1))
        Forwarder.drain(scope)

        [entry] = Queue.pending(scope, 10)
        assert entry.attempts == 1
        assert entry.last_error =~ "unreachable"
        assert entry.status == "pending"
      end)
    end

    test "when the adapter is back, every queued receipt is acknowledged, oldest first", %{
      scope: scope
    } do
      with_authority(TestAuthority.Unreachable, fn ->
        for n <- 1..6, do: {:ok, _} = Receipts.append(scope, decision(n))
        Forwarder.drain(scope)
        assert Queue.depth(scope) == 6
      end)

      with_authority(TestAuthority.Recorder, fn ->
        TestAuthority.Recorder.start()

        assert %{acked: 6, failed: 0} = Forwarder.drain(scope)
        assert Queue.depth(scope) == 0

        assert TestAuthority.Recorder.seen() == [1, 2, 3, 4, 5, 6],
               "the adapter was offered receipts out of order. A far side holding row 4 but not " <>
                 "row 3 has a gap it cannot see."
      end)
    end

    test "a scope stops at its first refusal rather than skipping past it", %{scope: scope} do
      for n <- 1..5, do: {:ok, _} = Receipts.append(scope, decision(n))

      with_authority(TestAuthority.FailsFrom, fn ->
        TestAuthority.FailsFrom.start(3)
        assert %{acked: 2, failed: 1} = Forwarder.drain(scope)

        assert Queue.depth(scope) == 3
        assert Enum.map(Queue.pending(scope, 10), & &1.seq) == [3, 4, 5]

        assert TestAuthority.FailsFrom.seen() == [1, 2, 3],
               "the forwarder offered rows after the one that failed"
      end)
    end

    test "the local authority acknowledges, so standalone Trinity exercises the same path", %{
      scope: scope
    } do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      assert Queue.depth(scope) == 3

      assert %{acked: 3, failed: 0} = Forwarder.drain(scope)
      assert Queue.depth(scope) == 0
    end
  end

  describe "acknowledgement is in order, and the queue says so" do
    test "acking a later receipt while an older one is pending is refused", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      [_first, second, _third] = Queue.pending(scope, 10)

      assert {:error, {:out_of_order, 1}} = Queue.ack(scope, second.receipt_hash)
      assert Queue.depth(scope) == 3
    end

    test "acking in order works, and acking twice is idempotent", %{scope: scope} do
      for n <- 1..2, do: {:ok, _} = Receipts.append(scope, decision(n))
      [first, second] = Queue.pending(scope, 10)

      assert :ok = Queue.ack(scope, first.receipt_hash)
      assert :ok = Queue.ack(scope, first.receipt_hash)
      assert :ok = Queue.ack(scope, second.receipt_hash)
      assert Queue.depth(scope) == 0
    end

    test "acking something never queued is an error, not a silent success", %{scope: scope} do
      assert {:error, :not_queued} = Queue.ack(scope, "no-such-hash")
    end
  end

  describe "AC4: past the bound, effects are denied rather than left unacknowledged" do
    test "an append past the bound is refused", %{scope: scope} do
      with_bound(3, fn ->
        for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))

        assert {:error, {:queue_full, 3, 3}} = Receipts.append(scope, decision(4))
      end)
    end

    test "the refusal is receipted, and that receipt is NOT itself queued", %{scope: scope} do
      with_bound(2, fn ->
        for n <- 1..2, do: {:ok, _} = Receipts.append(scope, decision(n))
        {:error, {:queue_full, _, _}} = Receipts.append(scope, decision(3))

        refusal =
          scope
          |> Receipts.list()
          |> Enum.find(&(&1.subject_ref && String.starts_with?(&1.subject_ref, "queue_full:")))

        assert refusal, "the machine refused an effect and recorded nothing"

        {:ok, body} = JSON.decode(refusal.signed_payload)
        assert get_in(body, ["decision", "outcome"]) == "refused"
        assert get_in(body, ["decision", "basis"]) == "queue"
        assert get_in(body, ["subject", "queue_bound"]) == 2

        refute RRepo.get_by(QueueEntry, receipt_hash: refusal.receipt_hash),
               "the queue-full refusal was itself queued. A full queue then cannot record that " <>
                 "it is full, which is a deadlock dressed as a safety property."

        assert Queue.depth(scope) == 2, "the refusal pushed the queue past its own bound"
      end)
    end

    test "the refused effect is not in the chain", %{scope: scope} do
      with_bound(2, fn ->
        for n <- 1..2, do: {:ok, _} = Receipts.append(scope, decision(n))
        {:error, _} = Receipts.append(scope, decision(3))

        refute Enum.any?(Receipts.list(scope), fn r ->
                 {:ok, body} = JSON.decode(r.signed_payload)
                 body["fingerprint"] == "ab3"
               end),
               "an effect was refused and written anyway"
      end)
    end

    test "draining the queue lets effects proceed again", %{scope: scope} do
      with_bound(2, fn ->
        for n <- 1..2, do: {:ok, _} = Receipts.append(scope, decision(n))
        assert {:error, {:queue_full, _, _}} = Receipts.append(scope, decision(3))

        assert %{acked: 2} = Forwarder.drain(scope)
        assert {:ok, _} = Receipts.append(scope, decision(4))
      end)
    end

    test "the chain still verifies across a refusal", %{scope: scope} do
      with_bound(2, fn ->
        for n <- 1..2, do: {:ok, _} = Receipts.append(scope, decision(n))
        {:error, _} = Receipts.append(scope, decision(3))
      end)

      :ok = Receipts.stop_writer(scope)
      {:ok, export} = Receipts.export(scope)
      assert {:ok, _} = Trinity.Receipts.Verifier.verify(export)
    end
  end
end
