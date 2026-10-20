# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.ChainWriter do
  @moduledoc """
  The one process that inserts into `receipts` for a chain scope (ADR-0013). Registered
  `:unique` in `Trinity.Registry` under `{__MODULE__, scope}`, started on demand under
  `Trinity.Receipts.WriterSupervisor`. Read-modify-write for the scope happens inside this
  process, so a predecessor read and a successor append cannot interleave and the chain
  cannot fork. `append/2` is a call: the caller learns whether its receipt is in the chain.

  Per row, since slice 140 (`Trinity.Receipts.V4`): the body is an N6 statement (`issuer`, `prev`,
  `seq`, `chain_scope`, `at`, `clock`, and `subject` and `decision` as ForeignRefs over their RFC 8785
  bytes, which are stored beside it), its `receipt_hash` its `statement_id`; decision, effect, boot
  and cap receipts are signed in the single-signer carrier through `Trinity.Receipts.KeyCustody`
  before the row is written, and a signer that cannot sign means no row and
  `{:error, {:signer_unavailable, reason}}` (never an unsigned row; AC5). Rows a chain already holds
  under v2 or v3 stay as they were signed; the first v4 row links to the last of them by
  `V4.legacy_link/1`.
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

  alias Trinity.N6.COSE

  alias Trinity.Receipts.{
    Checkpoint,
    Clock,
    Envelope,
    KeyCustody,
    KeyRegistry,
    Queue,
    Receipt,
    Signer,
    V4
  }

  alias Trinity.Repo.Receipts, as: Repo

  require Logger

  @default_every 100
  @default_after_ms 5_000

  # `prev_link` is the tail's link id, 48 bytes: its `statement_id`, or for a v2 or v3 tail the
  # SHA-384 of its PAE bytes (`V4.legacy_link/1`).
  defstruct scope: nil,
            seq: 0,
            prev_link: nil,
            clock: nil,
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
      {:ok, receipt, state} ->
        {:reply, {:ok, receipt}, maybe_checkpoint(receipt, state)}

      # A refusal that was itself receipted: the reply is the error, and the state advances,
      # because the refusal row is in the chain and the tail moved.
      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

    forward? = Map.get(attrs, :forward, true)

    with :ok <- check_queue_bound(forward?, state),
         {:ok, selection} <- selection(),
         {row, at, clock} = build_row(attrs, kind, selection, state),
         :ok <- check_clock(clock, state),
         {:ok, row} <- row_ok(row),
         {:ok, carrier} <- sign_if_needed(kind, row.body, selection) do
      insert_row(signed(row, carrier, at), state, clock, forward?)
    else
      {:error, {:clock_regression, offered, held}} ->
        refuse_clock_regression(offered, held, state)

      {:error, {:queue_full, depth, bound}} ->
        refuse_queue_full(depth, bound, state)

      other ->
        other
    end
  end

  # Slice 026, AC4. The bound is a refusal, not a buffer: past it the effect is denied rather than
  # performed and left unacknowledged. An unbounded queue turns a long partition into an unbounded
  # liability, where the machine keeps acting, nothing can be confirmed, and the operator finds out
  # when the disk fills.
  defp check_queue_bound(false, _state), do: :ok

  defp check_queue_bound(true, state) do
    depth = Queue.depth(state.scope)
    bound = Queue.bound()
    if depth >= bound, do: {:error, {:queue_full, depth, bound}}, else: :ok
  end

  defp refuse_queue_full(depth, bound, state) do
    attrs = %{
      kind: "decision",
      subject: %{
        "chain_scope" => state.scope,
        "queue_depth" => depth,
        "queue_bound" => bound
      },
      decision: %{
        "outcome" => "refused",
        "basis" => "queue",
        "reason" =>
          "the outbound receipt queue is at its bound: refusing the effect rather than " <>
            "performing it and leaving it unacknowledged"
      },
      subject_ref: "queue_full:#{state.scope}:#{state.seq}",
      # Not itself queued. If it were, a full queue could not record that it was full, which is a
      # deadlock dressed as a safety property.
      forward: false
    }

    case do_append_unchecked(attrs, state) do
      {:ok, _receipt, state} -> {:error, {:queue_full, depth, bound}, state}
      {:error, why} -> {:error, {:queue_full_unrecorded, why}}
    end
  end

  # Slice 026, AC3. The writer's own clock cannot go backwards: `Clock.next/2` is monotone even
  # when the host's wall clock is not. This guards the other way in, which is a clock supplied with
  # the attributes, as the merge path and an adapter's replay both do. A row that claims to precede
  # one already in the chain is refused, and the refusal is itself a receipt, because a refusal that
  # leaves no record is indistinguishable from the call never having been made.
  defp check_clock(_clock, %{clock: nil}), do: :ok

  defp check_clock(clock, %{clock: held}) do
    if Clock.compare(clock, held) == :gt,
      do: :ok,
      else: {:error, {:clock_regression, clock, held}}
  end

  defp refuse_clock_regression(offered, held, state) do
    attrs = %{
      kind: "decision",
      subject: %{
        "chain_scope" => state.scope,
        "offered_clock" => Clock.to_map(offered),
        "held_clock" => Clock.to_map(held)
      },
      decision: %{
        "outcome" => "refused",
        "basis" => "clock",
        "reason" =>
          "the offered clock does not follow the chain tail: a receipt may not claim to precede " <>
            "a row already written"
      },
      subject_ref: "clock_regression:#{state.scope}:#{state.seq}"
    }

    # The refusal takes a fresh clock of its own, which is monotone by construction, so recording a
    # refusal can never itself be refused.
    case do_append_unchecked(attrs, state) do
      {:ok, _receipt, state} -> {:error, {:clock_regression, offered, held}, state}
      {:error, why} -> {:error, {:clock_regression_unrecorded, why}}
    end
  end

  defp do_append_unchecked(attrs, state) do
    with {:ok, selection} <- selection(),
         {row, at, clock} = build_row(Map.delete(attrs, :clock), "decision", selection, state),
         {:ok, row} <- row_ok(row),
         {:ok, carrier} <- sign_if_needed("decision", row.body, selection) do
      insert_row(
        signed(row, carrier, at),
        state,
        clock,
        Map.get(attrs, :forward, true)
      )
    end
  end

  defp build_row(attrs, kind, selection, state) do
    seq = state.seq + 1
    at = DateTime.utc_now()
    clock = Map.get(attrs, :clock) || Clock.next(state.clock)
    subject = Map.get(attrs, :subject, %{})
    subject_bytes = Envelope.canonical(subject)
    decision_bytes = Map.get(attrs, :decision) && Envelope.canonical(Map.get(attrs, :decision))

    body =
      V4.row_body(kind, %{
        issuer: issuer(),
        seq: seq,
        chain_scope: state.scope,
        prev: state.prev_link,
        at: DateTime.to_unix(at, :microsecond),
        clock: {clock.wall, clock.counter, clock.node},
        subject: subject_bytes,
        decision: decision_bytes,
        fingerprint: Map.get(attrs, :fingerprint)
      })

    row = %Receipt{
      chain_scope: state.scope,
      seq: seq,
      prev_hash: state.prev_link && V4.hex(state.prev_link),
      receipt_hash: statement_hex(kind, body),
      scheme: selection.scheme,
      kind: kind,
      # v2 and v3 rows keep their RFC 8785 body here; a v4 row's body is `body`. The column is NOT
      # NULL and SQLite cannot relax that in place.
      signed_payload: "",
      body: body,
      subject_bytes: subject_bytes,
      decision_bytes: decision_bytes,
      key_id: selection.key_id,
      subject: subject,
      subject_ref: Map.get(attrs, :subject_ref),
      meta: Map.get(attrs, :meta, %{})
    }

    {row, at, clock}
  end

  defp statement_hex(kind, {:ok, body}), do: V4.hex(V4.statement_id(kind, body))
  defp statement_hex(_kind, {:error, _code}), do: nil

  # A signed row keeps its N6 signature in `signature` as well as in its carrier, as a checkpoint
  # does, so "signed" reads the same for a v4 row as for a v3 one; the carrier is what a verifier
  # reads.
  defp signed(row, nil, at), do: %{row | inserted_at: at}

  defp signed(row, carrier, at) do
    {:ok, %{signature: signature}} = Trinity.N6.Carrier.decode(carrier)
    %{row | carrier: carrier, signature: signature, inserted_at: at}
  end

  # A body the profile refuses is a bug in the caller's fields (a float in a fingerprint, say), never
  # a row: it is refused with the profile's code.
  defp row_ok(%Receipt{body: {:ok, body}} = row), do: {:ok, %{row | body: body}}
  defp row_ok(%Receipt{body: {:error, code}}), do: {:error, {:body_not_n6, code}}

  # The issuer every v4 body names: this installation, by the device id its clock already carries.
  # Provisional until the profile's issuer key descriptor (r3 section 8.2) exists.
  defp issuer, do: "trinity:" <> Clock.node_id()

  # The receipt and its queue entry land together or not at all. A receipt in the chain with no
  # queue entry is one the far side will never see and nothing will ever notice; a queue entry with
  # no receipt is a promise about a row that does not exist.
  defp insert_row(%Receipt{} = row, state, clock, forward?) do
    case Repo.transaction(fn -> insert_and_queue(row, forward?) end) do
      {:ok, receipt} ->
        state = %{state | seq: receipt.seq, prev_link: link(receipt), clock: clock}
        {:ok, receipt, track_uncovered(receipt, state)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_and_queue(row, forward?) do
    case Repo.insert(row) do
      {:ok, receipt} -> queue_entry(receipt, forward?)
      {:error, changeset} -> Repo.rollback({:insert, changeset.errors})
    end
  end

  defp queue_entry(receipt, false), do: receipt

  defp queue_entry(receipt, true) do
    case Repo.insert(Queue.entry_changeset(receipt)) do
      {:ok, _entry} -> receipt
      {:error, changeset} -> Repo.rollback({:queue_insert, changeset.errors})
    end
  end

  defp sign_if_needed(kind, body, selection) do
    if Receipt.signed?(kind), do: sign_body(kind, body, selection), else: {:ok, nil}
  end

  # The carrier for a body: its ToBeSigned signed by the key in custody, as the key's algorithm
  # needs (`V4.carrier/4`).
  defp sign_body(kind, body, %{n6_alg: alg, public: public}) do
    protected = V4.protected(kind, alg, public)

    case KeyCustody.sign(COSE.to_be_signed(protected, body)) do
      {:ok, sig} ->
        # fix(s024) at slice 032: a signer that signs again clears the alarm, as Alarm's
        # doc has said since 024; before this nothing did.
        if Trinity.Receipts.Alarm.set?(), do: Trinity.Receipts.Alarm.clear()

        case V4.carrier(protected, body, alg, sig) do
          {:ok, carrier} -> {:ok, carrier}
          :error -> {:error, {:signer_unavailable, :signature_not_convertible}}
        end

      {:error, reason} ->
        Trinity.Receipts.Alarm.signer_unavailable(reason)
        {:error, {:signer_unavailable, reason}}
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
    with {:ok, selection} <- selection(),
         {:ok, row} <- build_checkpoint(state, reason, selection),
         {:ok, carrier} <- sign_body("checkpoint", row.body, selection),
         {:ok, %{signature: signature}} <- Trinity.N6.Carrier.decode(carrier) do
      # The signature column is NOT NULL from slice 024; a v4 checkpoint keeps its N6 signature
      # there too, and the carrier is what a verifier reads.
      insert_checkpoint(%{row | carrier: carrier, signature: signature}, state)
    end
  end

  defp build_checkpoint(state, reason, selection) do
    at = DateTime.utc_now()
    boot = Trinity.Receipts.boot_hash()

    fields = %{
      issuer: issuer(),
      first_seq: state.uncovered_first,
      last_seq: state.seq,
      chain_scope: state.scope,
      tail: state.prev_link,
      boot: boot,
      reason: reason,
      at: DateTime.to_unix(at, :microsecond)
    }

    case V4.checkpoint_body(fields) do
      {:ok, body} ->
        {:ok,
         %Checkpoint{
           chain_scope: state.scope,
           boot_receipt_hash: boot,
           first_seq: state.uncovered_first,
           last_seq: state.seq,
           tail_hash: V4.hex(state.prev_link),
           scheme: selection.scheme,
           signed_payload: "",
           body: body,
           key_id: selection.key_id,
           reason: reason,
           inserted_at: at
         }}

      {:error, code} ->
        {:error, {:body_not_n6, code}}
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

  # The tail's clock is read back so the chain stays monotone across a restart. A `v2` tail has
  # none, and a chain that crosses the bump simply starts its clock at the first `v3` row.
  defp tail_clock(nil), do: nil

  defp tail_clock(%Receipt{body: body, kind: kind}) when is_binary(body) do
    case V4.read(kind, body) do
      {:ok, %{19 => %{1 => w, 2 => c, 3 => {:text, n}}}} -> %Clock{wall: w, counter: c, node: n}
      _ -> nil
    end
  end

  defp tail_clock(%Receipt{signed_payload: payload}) do
    with {:ok, body} <- JSON.decode(payload),
         {:ok, clock} <- Clock.from_map(body["clock"]) do
      clock
    else
      _ -> nil
    end
  end

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
         prev_link: tail && link(tail),
         clock: tail_clock(tail),
         uncovered_first: first,
         uncovered_count: count
       }}
    end
  end

  defp check_tail(nil), do: :ok

  defp check_tail(%Receipt{body: body} = tail) when is_binary(body) do
    if V4.hex(V4.statement_id(tail.kind, body)) == tail.receipt_hash,
      do: :ok,
      else: {:error, {:tail_hash_mismatch, tail.seq}}
  end

  defp check_tail(%Receipt{} = tail) do
    bytes = Envelope.pae(Envelope.receipt_type(tail.scheme), tail.signed_payload)

    if Envelope.hash(bytes) == tail.receipt_hash,
      do: :ok,
      else: {:error, {:tail_hash_mismatch, tail.seq}}
  end

  # A row's link id: a v4 row's `statement_id` (its `receipt_hash`), or SHA-384 over a v2 or v3 row's
  # PAE bytes.
  defp link(%Receipt{body: body, receipt_hash: hash}) when is_binary(body),
    do: Base.decode16!(hash, case: :lower)

  defp link(%Receipt{} = r),
    do: V4.legacy_link(Envelope.pae(Envelope.receipt_type(r.scheme), r.signed_payload))

  defp check_checkpoint(nil, _scope), do: :ok

  defp check_checkpoint(%Checkpoint{body: body} = cp, scope) when is_binary(body) do
    row = Repo.one(from r in Receipt, where: r.chain_scope == ^scope and r.seq == ^cp.last_seq)

    with true <- row != nil || {:error, {:checkpoint_tail_not_in_chain, cp.last_seq}},
         {:ok, rows} <- KeyRegistry.read(keys_dir()) do
      opts = [registry: rows, entry: KeyCustody.profile()]

      case V4.verify_checkpoint(Checkpoint.to_export(cp), link(row), opts) do
        :ok ->
          :ok

        {:error, 5, {:alg_unavailable, _at, alg}} ->
          {:error, {:checkpoint_alg_unavailable, cp.last_seq, alg}}

        {:error, _exit, {:checkpoint_body_mismatch, _}} ->
          {:error, {:checkpoint_tail_not_in_chain, cp.last_seq}}

        {:error, 1, {:n6, _at, :signature_invalid}} ->
          {:error, {:checkpoint_signature_invalid, cp.last_seq}}

        {:error, _exit, reason} ->
          {:error, {:checkpoint_invalid, cp.last_seq, reason}}
      end
    end
  end

  defp check_checkpoint(%Checkpoint{} = cp, scope) do
    row = Repo.one(from r in Receipt, where: r.chain_scope == ^scope and r.seq == ^cp.last_seq)

    with true <-
           (row && row.receipt_hash == cp.tail_hash) ||
             {:error, {:checkpoint_tail_not_in_chain, cp.last_seq}},
         {:ok, impl} <-
           Signer.impl_for_scheme(cp.scheme) |> ok_or({:error, {:unknown_scheme, cp.scheme}}),
         {:ok, pub} <- public_key(cp.key_id) do
      bytes = Envelope.pae(Envelope.checkpoint_type(cp.scheme), cp.signed_payload)

      case Signer.check(impl, bytes, cp.signature, pub) do
        :ok ->
          :ok

        :invalid ->
          {:error, {:checkpoint_signature_invalid, cp.last_seq}}

        # Slice 139: a checkpoint this runtime cannot judge (one signed before the node entered FIPS
        # mode, say) stops the writer with the reason. Before 139 it was an exception out of
        # `:crypto.verify`, which stopped the writer just the same but said nothing about why.
        :alg_unavailable ->
          {:error, {:checkpoint_alg_unavailable, cp.last_seq, Atom.to_string(impl.algorithm())}}

        :key_unusable ->
          {:error, {:checkpoint_key_unusable, cp.last_seq, cp.key_id}}
      end
    end
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, err), do: err

  defp keys_dir do
    case KeyCustody.selected() do
      %{keys_dir: d} -> d
      _ -> KeyCustody.keys_dir()
    end
  end

  defp public_key(key_id) do
    with {:ok, rows} <- KeyRegistry.read(keys_dir()),
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
