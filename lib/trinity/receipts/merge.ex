# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Merge do
  @moduledoc """
  Reconciles this machine's chain with another device's after a partition (slice 026).

  ## What a merge is allowed to do, which is almost nothing

  **It never rewrites either side.** Not the local rows, not the remote export. A receipt is
  evidence, and evidence that a later process can edit to make two accounts agree is not evidence.
  So this does not merge in the sense of producing one reconciled chain: both chains stay exactly
  as they were, and what the merge produces is a **record of where they disagree**.

  That is the honest outcome. Two devices that both acted while unable to see each other produced
  two true accounts of what each did. Nothing available afterwards can turn those into one account
  of what happened, and a system that claimed to would be inventing the part it could not know.
  What an auditor needs is to be told precisely where the accounts part company, and for that
  statement to be signed.

  ## What it records

  For each differing position, one conflict receipt naming the position, both hashes, and both
  devices. One receipt per divergence rather than one for the whole run, because an auditor asking
  what happened at row 9 deserves an answer about row 9.

  Identical chains produce nothing at all: a merge that writes a receipt saying "no conflict" every
  time two devices sync turns the chain into a log of its own housekeeping.

  ## What it refuses

  A remote export that does not verify is refused before anything is compared. Recording a conflict
  against an unverifiable chain would be recording that this machine disagrees with an assertion
  nobody made, and it would let anyone who can reach the merge entry point write conflict receipts
  into the local chain by handing it invented rows.
  """

  alias Trinity.Receipts
  alias Trinity.Receipts.{Merkle, Verifier}

  @typedoc "What a merge did."
  @type outcome ::
          {:ok, :identical, map()}
          | {:ok, :diverged, map()}
          | {:error, term()}

  @doc """
  Compares the local chain for `scope` with a remote export and records the divergences.

  The remote export is the same shape `Trinity.Receipts.export/1` produces, from the other device.
  It is verified first, and refused if it does not verify.

  Returns `{:ok, :identical, summary}` when the tree heads match, or `{:ok, :diverged, summary}`
  with a conflict receipt written for each differing position. The summary carries both heads and
  the positions, so a caller can report without re-reading the chain.
  """
  @spec merge(String.t(), map()) :: outcome()
  def merge(scope, remote_export) when is_binary(scope) and is_map(remote_export) do
    with :ok <- verify_remote(remote_export) do
      local_hashes = scope |> Receipts.list() |> Enum.map(& &1.receipt_hash)
      remote_rows = remote_export["receipts"] |> Enum.sort_by(& &1["seq"])
      remote_hashes = Enum.map(remote_rows, & &1["receipt_hash"])

      summary = %{
        local_head: Merkle.root(local_hashes),
        remote_head: Merkle.root(remote_hashes),
        local_rows: length(local_hashes),
        remote_rows: length(remote_hashes)
      }

      case Merkle.compare(local_hashes, remote_hashes) do
        :identical ->
          {:ok, :identical, Map.put(summary, :conflicts, [])}

        {:diverged, positions} ->
          record_conflicts(scope, positions, local_hashes, remote_rows, summary)
      end
    end
  end

  @doc """
  This machine's tree head for a scope: one value that answers "are we the same?".

  Sent to the other side instead of the chain. Equal heads mean every row matches, and that costs
  one comparison rather than one message per row, which is the point of doing this with a tree on a
  link that has just come back.
  """
  @spec head(String.t()) :: String.t()
  def head(scope), do: scope |> Receipts.list() |> Enum.map(& &1.receipt_hash) |> Merkle.root()

  defp verify_remote(export) do
    case Verifier.verify(export) do
      {:ok, _} -> :ok
      {:error, code, reason} -> {:error, {:remote_does_not_verify, code, reason}}
    end
  end

  defp record_conflicts(scope, positions, local_hashes, remote_rows, summary) do
    results =
      Enum.map(positions, fn position ->
        local = Enum.at(local_hashes, position - 1)
        remote_row = Enum.at(remote_rows, position - 1)

        Receipts.append(scope, %{
          kind: "decision",
          subject: %{
            "chain_scope" => scope,
            "seq" => position,
            "local_receipt_hash" => local,
            "remote_receipt_hash" => remote_row && remote_row["receipt_hash"],
            "local_head" => summary.local_head,
            "remote_head" => summary.remote_head,
            "remote_device" => device_of(remote_row)
          },
          decision: %{
            "outcome" => "conflict",
            "basis" => "merge",
            "reason" => reason_for(local, remote_row)
          },
          subject_ref: "merge_conflict:#{scope}:#{position}"
        })
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        {:ok, :diverged, Map.put(summary, :conflicts, positions)}

      {:error, why} ->
        {:error, {:conflict_not_recorded, why}}
    end
  end

  defp reason_for(nil, _remote),
    do: "the remote chain has a row at this position and this one does not"

  defp reason_for(_local, nil),
    do: "this chain has a row at this position and the remote does not"

  defp reason_for(_local, _remote),
    do: "both chains have a row at this position and they are not the same row"

  defp device_of(nil), do: nil

  defp device_of(row) do
    with payload when is_binary(payload) <- row["signed_payload"],
         {:ok, body} <- JSON.decode(payload),
         %{"node" => node} <- body["clock"] do
      node
    else
      _ -> nil
    end
  end
end
