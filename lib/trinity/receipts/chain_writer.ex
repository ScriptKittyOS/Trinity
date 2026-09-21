# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.ChainWriter do
  @moduledoc """
  The one process that inserts into `receipts` for a chain scope (ADR-0013). Registered
  `:unique` in `Trinity.Registry` under `{__MODULE__, scope}`, started on demand under
  `Trinity.Receipts.WriterSupervisor`. Read-modify-write for the scope happens inside this
  process, so a predecessor read and a successor append cannot interleave and the chain
  cannot fork. `append/2` is a call: the caller learns whether its receipt is in the chain.

  Per row: the body (`scheme`, `seq`, `chain_scope`, `prev_hash`, `kind`, `subject`,
  `decision`, `fingerprint`, `at`, `key_id`) is canonicalised, wrapped in the PAE with the
  receipt type, hashed; decision, effect, boot and cap receipts are signed through
  `Trinity.Receipts.KeyCustody` before the row is written, and a signer that cannot sign
  means no row and `{:error, {:signer_unavailable, reason}}` (never an unsigned row; AC5).
  Query receipts are chained unsigned and covered by a checkpoint every N rows, every T
  milliseconds after the first uncovered row, on shutdown, and on rehydrate before a new row
  is accepted (amendment 5, AC9).

  On start the writer rehydrates the tail: it recomputes the tail row's hash from its stored
  body (a tail altered on disk stops the writer with the reason), checks the newest
  checkpoint names a tail hash that is in the chain and verifies under its key (C2SP's rule:
  never sign a checkpoint inconsistent with one signed before), then checkpoints any
  uncovered query rows.
  """
  # Temporary: writers start on demand and a crashed one is started again by the next
  # append, which rehydrates. A supervisor restart loop on a chain that refuses to start
  # (`{:chain_inconsistent, ...}`) would take the supervisor down with it.
  use GenServer, restart: :temporary

  import Ecto.Query

  alias Trinity.Receipts.{Checkpoint, Envelope, KeyCustody, KeyRegistry, Receipt, Signer}
  alias Trinity.Repo.Receipts, as: Repo

  require Logger

  @default_every 100
  @default_after_ms 5_000

  defstruct scope: nil,
            seq: 0,
            prev_hash: nil,
            uncovered_first: nil,
            uncovered_count: 0,
            timer: nil

  @doc "The registry name of a scope's writer."
  @spec via(String.t()) :: {:via, Registry, {Trinity.Registry, {module(), String.t()}}}
  def via(scope), do: {:via, Registry, {Trinity.Registry, {__MODULE__, scope}}}

  @doc false
  def start_link(scope) when is_binary(scope),
    do: GenServer.start_link(__MODULE__, scope, name: via(scope))

  @doc "The writer's pid for a scope, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(scope) do
    case Registry.lookup(Trinity.Registry, {__MODULE__, scope}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Appends a receipt to the scope's chain. `attrs`: `kind` (one of `Receipt.kinds/0`),
  `subject` (map), `decision` (map or nil), `fingerprint` (hex or nil), `subject_ref`,
  `meta` (unsigned).
  """
  @spec append(pid() | String.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
  def append(scope, attrs) when is_binary(scope), do: GenServer.call(via(scope), {:append, attrs})
  def append(pid, attrs) when is_pid(pid), do: GenServer.call(pid, {:append, attrs})

  @doc "Forces a checkpoint over any uncovered query rows now; `{:ok, nil}` when there are none."
  @spec checkpoint(pid() | String.t(), String.t()) ::
          {:ok, Checkpoint.t() | nil} | {:error, term()}
  def checkpoint(scope, reason \\ "manual")

  def checkpoint(scope, reason) when is_binary(scope),
    do: GenServer.call(via(scope), {:checkpoint, reason})

  def checkpoint(pid, reason) when is_pid(pid), do: GenServer.call(pid, {:checkpoint, reason})

  @doc "The checkpoint window in rows and milliseconds, from config."
  @spec window() :: {pos_integer(), pos_integer()}
  def window do
    cfg = Application.get_env(:trinity, :receipts, [])

    {Keyword.get(cfg, :checkpoint_every, @default_every),
     Keyword.get(cfg, :checkpoint_after_ms, @default_after_ms)}
  end

  ## Server

  @impl true
  def init(scope) do
    Process.flag(:trap_exit, true)

    case rehydrate(scope) do
      {:ok, state} -> {:ok, state, {:continue, :cover_tail}}
      {:error, reason} -> {:stop, {:chain_inconsistent, scope, reason}}
    end
  end

  @impl true
  def handle_continue(:cover_tail, state) do
    case write_checkpoint(state, "rehydrate") do
      {:ok, _, state} ->
        {:noreply, state}

      {:error, reason} ->
        # Uncovered query rows stay uncovered until a signer is back; the writer runs.
        Logger.warning(
          "receipts: #{state.scope}: rehydrate checkpoint not written: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:append, attrs}, _from, state) do
    case do_append(attrs, state) do
      {:ok, receipt, state} -> {:reply, {:ok, receipt}, maybe_checkpoint(receipt, state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkpoint, reason}, _from, state) do
    case write_checkpoint(state, reason) do
      {:ok, cp, state} -> {:reply, {:ok, cp}, state}
      {:error, why} -> {:reply, {:error, why}, state}
    end
  end

  @impl true
  def handle_info(:checkpoint_timer, state) do
    state = %{state | timer: nil}

    case write_checkpoint(state, "time") do
      {:ok, _, state} -> {:noreply, state}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case write_checkpoint(state, "shutdown") do
      {:ok, _, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "receipts: #{state.scope}: shutdown checkpoint not written: #{inspect(reason)}"
        )
    end
  end

  ## The append

  defp do_append(attrs, state) do
    kind = Map.fetch!(attrs, :kind)

    unless kind in Receipt.kinds(),
      do: raise(ArgumentError, "unknown receipt kind #{inspect(kind)}")

    with {:ok, %{scheme: scheme, key_id: key_id}} <- selection(),
         {row, at} = build_row(attrs, kind, scheme, key_id, state),
         bytes = Envelope.pae(Envelope.receipt_type(scheme), row.signed_payload),
         {:ok, signature} <- sign_if_needed(kind, bytes) do
      insert_row(%{row | signature: signature, inserted_at: at}, state)
    end
  end

  defp build_row(attrs, kind, scheme, key_id, state) do
    seq = state.seq + 1
    at = DateTime.utc_now()

    body = %{
      "scheme" => scheme,
      "seq" => seq,
      "chain_scope" => state.scope,
      "prev_hash" => state.prev_hash,
      "kind" => kind,
      "subject" => Map.get(attrs, :subject, %{}),
      "decision" => Map.get(attrs, :decision),
      "fingerprint" => Map.get(attrs, :fingerprint),
      "at" => DateTime.to_iso8601(at),
      "key_id" => key_id
    }

    payload = Envelope.canonical(body)
    hash = Envelope.hash(Envelope.pae(Envelope.receipt_type(scheme), payload))

    row = %Receipt{
      chain_scope: state.scope,
      seq: seq,
      prev_hash: state.prev_hash,
      receipt_hash: hash,
      scheme: scheme,
      kind: kind,
      signed_payload: payload,
      key_id: key_id,
      subject: Map.get(attrs, :subject, %{}),
      subject_ref: Map.get(attrs, :subject_ref),
      meta: Map.get(attrs, :meta, %{})
    }

    {row, at}
  end

  defp insert_row(%Receipt{} = row, state) do
    case Repo.insert(row) do
      {:ok, receipt} ->
        state = %{state | seq: receipt.seq, prev_hash: receipt.receipt_hash}
        {:ok, receipt, track_uncovered(receipt, state)}

      {:error, changeset} ->
        {:error, {:insert, changeset.errors}}
    end
  end

  defp sign_if_needed(kind, bytes) do
    if Receipt.signed?(kind) do
      case KeyCustody.sign(bytes) do
        {:ok, sig} ->
          # fix(s024) at slice 032: a signer that signs again clears the alarm, as Alarm's
          # doc has said since 024; before this nothing did.
          if Trinity.Receipts.Alarm.set?(), do: Trinity.Receipts.Alarm.clear()
          {:ok, sig}

        {:error, reason} ->
          Trinity.Receipts.Alarm.signer_unavailable(reason)
          {:error, {:signer_unavailable, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp selection do
    case KeyCustody.selected() do
      %{} = s -> {:ok, s}
      {:unavailable, reason} -> alarm_and_error(reason)
      nil -> alarm_and_error(:not_booted)
    end
  end

  defp alarm_and_error(reason) do
    Trinity.Receipts.Alarm.signer_unavailable(reason)
    {:error, {:signer_unavailable, reason}}
  end

  ## Checkpoints over query rows

  defp track_uncovered(%Receipt{kind: "query", seq: seq}, state) do
    {_every, after_ms} = window()
    first = state.uncovered_first || seq
    timer = state.timer || Process.send_after(self(), :checkpoint_timer, after_ms)
    %{state | uncovered_first: first, uncovered_count: state.uncovered_count + 1, timer: timer}
  end

  defp track_uncovered(_receipt, state), do: state

  defp maybe_checkpoint(%Receipt{kind: "query"}, state) do
    {every, _} = window()

    if state.uncovered_count >= every do
      case write_checkpoint(state, "count") do
        {:ok, _, state} -> state
        {:error, _} -> state
      end
    else
      state
    end
  end

  defp maybe_checkpoint(_receipt, state), do: state

  defp write_checkpoint(%{uncovered_first: nil} = state, _reason), do: {:ok, nil, state}

  defp write_checkpoint(state, reason) do
    with {:ok, %{scheme: scheme, key_id: key_id}} <- selection(),
         {row, bytes} = build_checkpoint(state, reason, scheme, key_id),
         {:ok, signature} <- sign_checkpoint(bytes) do
      insert_checkpoint(%{row | signature: signature}, state)
    end
  end

  defp build_checkpoint(state, reason, scheme, key_id) do
    at = DateTime.utc_now()

    body = %{
      "scheme" => scheme,
      "chain_scope" => state.scope,
      "boot_receipt_hash" => Trinity.Receipts.boot_hash(),
      "first_seq" => state.uncovered_first,
      "last_seq" => state.seq,
      "tail_hash" => state.prev_hash,
      "key_id" => key_id,
      "reason" => reason,
      "at" => DateTime.to_iso8601(at)
    }

    payload = Envelope.canonical(body)

    row = %Checkpoint{
      chain_scope: state.scope,
      boot_receipt_hash: body["boot_receipt_hash"],
      first_seq: state.uncovered_first,
      last_seq: state.seq,
      tail_hash: state.prev_hash,
      scheme: scheme,
      signed_payload: payload,
      key_id: key_id,
      reason: reason,
      inserted_at: at
    }

    {row, Envelope.pae(Envelope.checkpoint_type(scheme), payload)}
  end

  defp sign_checkpoint(bytes) do
    case KeyCustody.sign(bytes) do
      {:ok, signature} ->
        if Trinity.Receipts.Alarm.set?(), do: Trinity.Receipts.Alarm.clear()
        {:ok, signature}

      {:error, why} ->
        Trinity.Receipts.Alarm.signer_unavailable(why)
        {:error, {:signer_unavailable, why}}
    end
  end

  defp insert_checkpoint(%Checkpoint{} = row, state) do
    case Repo.insert(row) do
      {:ok, cp} ->
        if state.timer, do: Process.cancel_timer(state.timer)
        {:ok, cp, %{state | uncovered_first: nil, uncovered_count: 0, timer: nil}}

      {:error, changeset} ->
        {:error, {:insert, changeset.errors}}
    end
  end

  ## Rehydrate

  defp rehydrate(scope) do
    tail =
      Repo.one(
        from r in Receipt, where: r.chain_scope == ^scope, order_by: [desc: r.seq], limit: 1
      )

    with :ok <- check_tail(tail),
         newest =
           Repo.one(
             from c in Checkpoint,
               where: c.chain_scope == ^scope,
               order_by: [desc: c.last_seq],
               limit: 1
           ),
         :ok <- check_checkpoint(newest, scope) do
      {first, count} = uncovered(scope, newest)

      {:ok,
       %__MODULE__{
         scope: scope,
         seq: (tail && tail.seq) || 0,
         prev_hash: tail && tail.receipt_hash,
         uncovered_first: first,
         uncovered_count: count
       }}
    end
  end

  defp check_tail(nil), do: :ok

  defp check_tail(%Receipt{} = tail) do
    bytes = Envelope.pae(Envelope.receipt_type(tail.scheme), tail.signed_payload)

    if Envelope.hash(bytes) == tail.receipt_hash,
      do: :ok,
      else: {:error, {:tail_hash_mismatch, tail.seq}}
  end

  defp check_checkpoint(nil, _scope), do: :ok

  defp check_checkpoint(%Checkpoint{} = cp, scope) do
    row = Repo.one(from r in Receipt, where: r.chain_scope == ^scope and r.seq == ^cp.last_seq)

    with true <-
           (row && row.receipt_hash == cp.tail_hash) ||
             {:error, {:checkpoint_tail_not_in_chain, cp.last_seq}},
         {:ok, impl} <-
           Signer.impl_for_scheme(cp.scheme) |> ok_or({:error, {:unknown_scheme, cp.scheme}}),
         {:ok, pub} <- public_key(cp.key_id),
         true <-
           impl.verify(
             Envelope.pae(Envelope.checkpoint_type(cp.scheme), cp.signed_payload),
             cp.signature,
             pub
           ) || {:error, {:checkpoint_signature_invalid, cp.last_seq}} do
      :ok
    end
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, err), do: err

  defp public_key(key_id) do
    dir =
      case KeyCustody.selected() do
        %{keys_dir: d} -> d
        _ -> KeyCustody.keys_dir()
      end

    with {:ok, rows} <- KeyRegistry.read(dir),
         %{} = row <- KeyRegistry.lookup(rows, key_id) || {:error, {:unknown_key_id, key_id}} do
      KeyRegistry.public_key(row) |> ok_or({:error, {:key_without_public, key_id}})
    end
  end

  # The uncovered query rows: after the newest checkpoint's last_seq (or from the start).
  defp uncovered(scope, newest) do
    since = (newest && newest.last_seq) || 0

    rows =
      Repo.all(
        from r in Receipt,
          where: r.chain_scope == ^scope and r.seq > ^since and r.kind == "query",
          select: r.seq,
          order_by: r.seq
      )

    case rows do
      [] -> {nil, 0}
      [first | _] -> {first, length(rows)}
    end
  end
end
