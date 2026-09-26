# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Queue do
  @moduledoc """
  The durable outbound queue: receipts awaiting acknowledgement by the authority adapter (slice 026).

  ## What it does and does not do

  It **carries envelopes and never re-signs them.** The stored `envelope` is the exported receipt
  byte for byte, so a delay, a retry or a re-delivery hands the adapter exactly the bytes that were
  signed. That is not an implementation preference: the external authority plane answered the
  question that blocked this slice by saying store-and-forward is invisible to them precisely
  because their verifiers check a signature over those bytes offline, and a queue that rebuilt an
  envelope at send time would break that without anything failing loudly.

  It **acknowledges in order.** A gap in acknowledgements is a gap in what the far side has seen,
  and an out-of-order ack would silently close one. `ack/2` refuses a receipt whose predecessors in
  the same scope are still pending.

  It is **bounded**, and the bound is a refusal rather than a buffer. Past the bound the writer
  refuses new forwardable receipts, so effects are denied rather than performed and left
  unacknowledged. An unbounded queue turns a long partition into an unbounded liability: the
  machine keeps acting, nothing can be confirmed, and the operator finds out when the disk fills.

  ## The one thing that is always recordable

  A queue-full refusal is written to the chain and is **not** itself queued. If it were, a full
  queue could not record that it was full, which is a deadlock dressed as a safety property. Its
  entry in the chain is a local fact about this machine's state, and the far side learns it when
  the backlog drains and the acknowledgement gap closes.
  """

  import Ecto.Query

  alias Trinity.Receipts.{QueueEntry, Receipt}
  alias Trinity.Repo.Receipts, as: Repo

  @default_bound 10_000

  @doc """
  The maximum number of pending entries a single chain scope may hold.

  `config :trinity, :receipts, queue_bound: n`. The default is deliberately large: the bound exists
  to stop an unbounded liability, not to be reached in ordinary operation.
  """
  @spec bound() :: pos_integer()
  def bound do
    Application.get_env(:trinity, :receipts, []) |> Keyword.get(:queue_bound, @default_bound)
  end

  @doc "Pending entries for a scope, oldest first."
  @spec pending(String.t(), pos_integer()) :: [QueueEntry.t()]
  def pending(scope, limit \\ 100) do
    Repo.all(
      from q in QueueEntry,
        where: q.chain_scope == ^scope and q.status == "pending",
        order_by: [asc: q.seq],
        limit: ^limit
    )
  end

  @doc "How many entries a scope has pending."
  @spec depth(String.t()) :: non_neg_integer()
  def depth(scope) do
    Repo.one(
      from q in QueueEntry,
        where: q.chain_scope == ^scope and q.status == "pending",
        select: count(q.id)
    ) || 0
  end

  @doc "Every scope with pending entries."
  @spec scopes_with_pending() :: [String.t()]
  def scopes_with_pending do
    Repo.all(
      from q in QueueEntry,
        where: q.status == "pending",
        distinct: true,
        select: q.chain_scope
    )
  end

  @doc "True when a scope is at or past the bound, so a forwardable receipt must be refused."
  @spec full?(String.t()) :: boolean()
  def full?(scope), do: depth(scope) >= bound()

  @doc """
  The changeset for queueing a receipt, for use inside the writer's transaction.

  Returned rather than inserted so that a receipt and its queue entry land together or not at all.
  A receipt in the chain with no queue entry is a receipt the far side will never see and nothing
  will ever notice; a queue entry with no receipt is a promise about a row that does not exist.
  """
  @spec entry_changeset(Receipt.t()) :: Ecto.Changeset.t()
  def entry_changeset(%Receipt{} = row) do
    QueueEntry.changeset(%QueueEntry{}, %{
      chain_scope: row.chain_scope,
      seq: row.seq,
      receipt_hash: row.receipt_hash,
      kind: row.kind,
      envelope: row |> Receipt.to_export() |> JSON.encode!(),
      status: "pending",
      queued_at: DateTime.utc_now()
    })
  end

  @doc """
  Marks an entry acknowledged, refusing an acknowledgement that would leave an older one pending.

  `{:error, {:out_of_order, first_pending_seq}}` when something older in the same scope has not been
  acknowledged. The far side may well have received them out of order; what it may not do is tell
  this side that a later receipt is safely recorded while an earlier one is not, because the gap
  that leaves is invisible afterwards.
  """
  @spec ack(String.t(), String.t()) :: :ok | {:error, term()}
  def ack(scope, receipt_hash) do
    case Repo.one(
           from q in QueueEntry,
             where: q.chain_scope == ^scope and q.receipt_hash == ^receipt_hash
         ) do
      nil ->
        {:error, :not_queued}

      %QueueEntry{status: "acked"} ->
        :ok

      %QueueEntry{} = entry ->
        case oldest_pending_seq(scope) do
          seq when seq == entry.seq ->
            entry
            |> QueueEntry.changeset(%{status: "acked", acked_at: DateTime.utc_now()})
            |> Repo.update()
            |> case do
              {:ok, _} -> :ok
              {:error, cs} -> {:error, {:ack_failed, cs.errors}}
            end

          older ->
            {:error, {:out_of_order, older}}
        end
    end
  end

  @doc "Records a failed delivery attempt without acknowledging it."
  @spec fail(QueueEntry.t(), term()) :: :ok
  def fail(%QueueEntry{} = entry, reason) do
    entry
    |> QueueEntry.changeset(%{
      attempts: entry.attempts + 1,
      last_error: reason |> inspect() |> String.slice(0, 200)
    })
    |> Repo.update()

    :ok
  end

  defp oldest_pending_seq(scope) do
    Repo.one(
      from q in QueueEntry,
        where: q.chain_scope == ^scope and q.status == "pending",
        select: min(q.seq)
    )
  end
end
