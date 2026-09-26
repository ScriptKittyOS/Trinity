# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.MergeTest do
  @moduledoc """
  Slice 026, AC2: two chains that diverged during a partition merge on reconnect with neither
  rewritten and a conflict receipt for each divergence.

  The thing being asserted is mostly a negative. A merge may not make two accounts agree, because
  nothing available after a partition can turn two true accounts of what each device did into one
  account of what happened. What it may do is say precisely where they part company, and sign that.
  """
  use Trinity.DataCase, async: false
  use ExUnitProperties

  alias Trinity.Receipts
  alias Trinity.Receipts.{Merge, Merkle, Verifier}

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

  # A second device's chain, built by running a second scope and relabelling its export to the
  # first scope's name. Two devices genuinely holding the same scope is exactly the partition case,
  # and this is the only way to produce one inside a single test VM.
  defp remote_chain(n, opts \\ []) do
    other = "test:" <> Trinity.UUID.generate()
    from = Keyword.get(opts, :from, 1)

    for i <- from..(from + n - 1), do: {:ok, _} = Receipts.append(other, decision(i))

    :ok = Receipts.stop_writer(other)
    {:ok, export} = Receipts.export(other)
    export
  end

  defp local_hashes(scope), do: scope |> Receipts.list() |> Enum.map(& &1.receipt_hash)

  describe "Merkle heads" do
    test "an empty chain has RFC 6962's empty-tree head" do
      assert Merkle.root([]) == :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    end

    test "the head changes when any row changes" do
      assert Merkle.root(["a", "b", "c"]) != Merkle.root(["a", "b", "d"])
    end

    test "order matters: the same rows in a different order are a different chain" do
      assert Merkle.root(["a", "b"]) != Merkle.root(["b", "a"])
    end

    test "a leaf is not an interior node, which is what stops the second-preimage attack" do
      # RFC 6962 section 2.1. Without the distinct prefixes, an interior node's hash could be
      # presented as a leaf and a shorter tree forged to match a longer one's head.
      left = Merkle.leaf("a")
      right = Merkle.leaf("b")
      interior = Merkle.node_hash(left, right)

      assert Merkle.leaf(left <> right) != interior
    end

    test "an odd node is promoted, not duplicated" do
      # Duplicating it is the Bitcoin construction (CVE-2012-2459) and lets distinct leaf sets
      # share a root, which here would mean two different chains comparing as identical.
      assert Merkle.root(["a", "b", "c"]) != Merkle.root(["a", "b", "c", "c"])
    end

    property "two lists share a head only when they are equal" do
      check all(
              a <- list_of(string(:alphanumeric, min_length: 1), max_length: 8),
              b <- list_of(string(:alphanumeric, min_length: 1), max_length: 8)
            ) do
        if Merkle.root(a) == Merkle.root(b), do: assert(a == b)
      end
    end
  end

  describe "AC2: chains that did not diverge" do
    test "identical chains report identical and write nothing", %{scope: scope} do
      for n <- 1..4, do: {:ok, _} = Receipts.append(scope, decision(n))
      :ok = Receipts.stop_writer(scope)
      {:ok, export} = Receipts.export(scope)

      before = Receipts.list(scope) |> length()

      assert {:ok, :identical, summary} = Merge.merge(scope, export)
      assert summary.local_head == summary.remote_head
      assert summary.conflicts == []

      assert Receipts.list(scope) |> length() == before,
             "a merge of two identical chains wrote a receipt. That turns the chain into a log " <>
               "of its own housekeeping."
    end

    test "head/1 is the same value the summary reports", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      assert Merge.head(scope) == Merkle.root(local_hashes(scope))
    end
  end

  describe "AC2: chains that diverged" do
    test "a conflict receipt is written for each differing position", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      remote = remote_chain(3)

      assert {:ok, :diverged, summary} = Merge.merge(scope, remote)

      assert summary.local_head != summary.remote_head
      assert summary.conflicts == [1, 2, 3]

      conflicts =
        scope
        |> Receipts.list()
        |> Enum.filter(
          &(&1.subject_ref && String.starts_with?(&1.subject_ref, "merge_conflict:"))
        )

      assert length(conflicts) == 3

      for row <- conflicts do
        {:ok, body} = JSON.decode(row.signed_payload)
        assert get_in(body, ["decision", "outcome"]) == "conflict"
        assert get_in(body, ["decision", "basis"]) == "merge"
        assert get_in(body, ["subject", "local_receipt_hash"])
        assert get_in(body, ["subject", "remote_receipt_hash"])
        assert get_in(body, ["subject", "remote_device"])
      end
    end

    test "neither side is rewritten", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      before = local_hashes(scope)

      remote = remote_chain(3)
      remote_before = remote["receipts"] |> Enum.map(& &1["receipt_hash"])

      {:ok, :diverged, _} = Merge.merge(scope, remote)

      after_merge = local_hashes(scope)

      assert Enum.take(after_merge, length(before)) == before,
             "the merge altered rows that were already in the local chain"

      assert remote["receipts"] |> Enum.map(& &1["receipt_hash"]) == remote_before,
             "the merge altered the remote export it was handed"
    end

    test "the local chain still verifies after the merge", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      {:ok, :diverged, _} = Merge.merge(scope, remote_chain(3))

      :ok = Receipts.stop_writer(scope)
      {:ok, export} = Receipts.export(scope)
      assert {:ok, _} = Verifier.verify(export)
    end

    test "a remote longer than the local reports the positions only it has", %{scope: scope} do
      for n <- 1..2, do: {:ok, _} = Receipts.append(scope, decision(n))

      assert {:ok, :diverged, summary} = Merge.merge(scope, remote_chain(4))
      assert summary.conflicts == [1, 2, 3, 4]

      row =
        scope
        |> Receipts.list()
        |> Enum.find(&(&1.subject_ref == "merge_conflict:#{scope}:4"))

      {:ok, body} = JSON.decode(row.signed_payload)

      assert get_in(body, ["decision", "reason"]) =~ "the remote chain has a row",
             "a position the remote has and this chain does not was not described as such"
    end

    test "a conflict names both heads, so a reader can check the comparison", %{scope: scope} do
      {:ok, _} = Receipts.append(scope, decision(1))
      remote = remote_chain(1)

      {:ok, :diverged, summary} = Merge.merge(scope, remote)

      row =
        scope
        |> Receipts.list()
        |> Enum.find(&(&1.subject_ref && String.starts_with?(&1.subject_ref, "merge_conflict:")))

      {:ok, body} = JSON.decode(row.signed_payload)

      assert get_in(body, ["subject", "local_head"]) == summary.local_head
      assert get_in(body, ["subject", "remote_head"]) == summary.remote_head
    end
  end

  describe "what a merge refuses" do
    test "a remote export that does not verify is refused before anything is compared", %{
      scope: scope
    } do
      {:ok, _} = Receipts.append(scope, decision(1))
      remote = remote_chain(2)

      tampered =
        update_in(remote["receipts"], fn rows ->
          Enum.map(rows, fn r -> %{r | "receipt_hash" => String.duplicate("0", 64)} end)
        end)

      assert {:error, {:remote_does_not_verify, _, _}} = Merge.merge(scope, tampered)

      refute Enum.any?(
               Receipts.list(scope),
               &(&1.subject_ref && String.starts_with?(&1.subject_ref, "merge_conflict:"))
             ),
             "a conflict was recorded against a chain that does not verify. That lets anyone who " <>
               "can reach the merge write conflict receipts by handing it invented rows."
    end
  end
end
