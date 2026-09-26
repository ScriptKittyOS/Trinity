# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.ChainWriterTest do
  @moduledoc "Slice 024, G1 line 3: one writer per scope, the chain, the checkpoints, the refusals."
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.{Alarm, ChainWriter, Checkpoint, Envelope, KeyCustody, Receipt, Signer}
  alias Trinity.Repo.Receipts, as: RRepo

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

  defp query(n), do: %{kind: "query", subject: %{"n" => n}}

  defp with_window(every, after_ms, fun) do
    old = Application.get_env(:trinity, :receipts, [])

    Application.put_env(
      :trinity,
      :receipts,
      Keyword.merge(old, checkpoint_every: every, checkpoint_after_ms: after_ms)
    )

    try do
      fun.()
    after
      Application.put_env(:trinity, :receipts, old)
    end
  end

  test "rows chain: gapless seq, each prev_hash the previous receipt_hash, signed kinds verify, query rows unsigned",
       %{scope: scope} do
    for n <- 1..5, do: assert({:ok, %Receipt{}} = Receipts.append(scope, decision(n)))
    for n <- 6..8, do: assert({:ok, %Receipt{}} = Receipts.append(scope, query(n)))
    rows = Receipts.list(scope)
    assert Enum.map(rows, & &1.seq) == Enum.to_list(1..8)
    assert hd(rows).prev_hash == nil

    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert b.prev_hash == a.receipt_hash end)

    %{impl: impl, keys_dir: dir, key_id: key_id} = KeyCustody.selected()
    {:ok, registry} = Receipts.KeyRegistry.read(dir)

    {:ok, pub} =
      registry |> Receipts.KeyRegistry.lookup(key_id) |> Receipts.KeyRegistry.public_key()

    for r <- rows do
      bytes = Envelope.pae(Envelope.receipt_type(r.scheme), r.signed_payload)
      assert r.receipt_hash == Envelope.hash(bytes)
      assert r.scheme == impl.scheme()
      assert r.key_id == key_id

      if r.kind == "query",
        do: assert(r.signature == nil),
        else: assert(impl.verify(bytes, r.signature, pub))
    end

    # The body carries the scheme, the seq, the scope and the key id (the R21 default set).
    body = JSON.decode!(hd(rows).signed_payload)

    assert Map.keys(body) |> Enum.sort() ==
             ~w(at chain_scope clock decision fingerprint key_id kind prev_hash scheme seq subject)

    assert body["scheme"] == impl.scheme()
  end

  test "concurrent appenders to one scope produce one chain: no two rows share a prev_hash", %{
    scope: scope
  } do
    {:ok, _} = Receipts.ensure_writer(scope)

    1..40
    |> Task.async_stream(fn n -> Receipts.append(scope, query(n)) end, max_concurrency: 40)
    |> Enum.each(fn {:ok, {:ok, %Receipt{}}} -> :ok end)

    rows = Receipts.list(scope)
    assert length(rows) == 40
    assert Enum.map(rows, & &1.seq) == Enum.to_list(1..40)
    prevs = rows |> Enum.map(& &1.prev_hash) |> Enum.reject(&is_nil/1)
    assert length(prevs) == length(Enum.uniq(prevs))
  end

  test "AC5 at the writer: the key removed mid-run, the next signed receipt is refused, the alarm sounds, no row is written",
       %{scope: scope} do
    %{key_path: path} = KeyCustody.selected()
    bytes = File.read!(path)

    on_exit(fn ->
      File.write!(path, bytes)
      Alarm.clear()
    end)

    Alarm.clear()
    assert {:ok, _} = Receipts.append(scope, decision(1))

    :telemetry.attach(
      "s024-alarm-test",
      Alarm.event(),
      fn _, m, meta, pid -> send(pid, {:alarm_event, m, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("s024-alarm-test") end)

    File.rm!(path)

    assert {:error, {:signer_unavailable, :signer_unavailable}} =
             Receipts.append(scope, decision(2))

    assert Alarm.set?()
    assert_receive {:alarm_event, %{count: 1}, %{reason: :signer_unavailable}}
    assert Receipts.count(scope) == 1
    assert Receipts.list(scope) |> Enum.all?(&(&1.signature != nil))

    # A query row is chained without a signature and still goes in; its checkpoint waits.
    assert {:ok, %Receipt{kind: "query"}} = Receipts.append(scope, query(3))
    File.write!(path, bytes)
    assert {:ok, _} = Receipts.append(scope, decision(4))
    # "Clears the alarm once a signer signs again" (Alarm's own doc): the signed append above
    # is that signing. Red at slice 032: nothing cleared it, and the fips leg's receipts test
    # met an alarm an earlier test had left set (run 35606884798).
    refute Alarm.set?()
  end

  describe "AC9: query checkpoints" do
    test "after N query receipts a checkpoint names the tail and its coverage; its signature verifies",
         %{scope: scope} do
      with_window(3, 60_000, fn ->
        for n <- 1..3, do: {:ok, _} = Receipts.append(scope, query(n))

        assert [%Checkpoint{first_seq: 1, last_seq: 3, reason: "count"} = cp] =
                 Receipts.checkpoints(scope)

        assert cp.tail_hash == Receipts.tail(scope).receipt_hash
        %{impl: impl, keys_dir: dir, key_id: key_id} = KeyCustody.selected()
        {:ok, registry} = Receipts.KeyRegistry.read(dir)

        {:ok, pub} =
          registry |> Receipts.KeyRegistry.lookup(key_id) |> Receipts.KeyRegistry.public_key()

        assert impl.verify(
                 Envelope.pae(Envelope.checkpoint_type(cp.scheme), cp.signed_payload),
                 cp.signature,
                 pub
               )

        body = JSON.decode!(cp.signed_payload)

        assert body["first_seq"] == 1 and body["last_seq"] == 3 and
                 body["tail_hash"] == cp.tail_hash

        # A fourth opens a new window; a decision receipt does not count toward it.
        {:ok, _} = Receipts.append(scope, query(4))
        {:ok, _} = Receipts.append(scope, decision(5))
        assert length(Receipts.checkpoints(scope)) == 1
      end)
    end

    test "T milliseconds after the first uncovered query row, a checkpoint is written by time", %{
      scope: scope
    } do
      with_window(1_000, 50, fn ->
        {:ok, _} = Receipts.append(scope, query(1))
        Process.sleep(150)

        assert [%Checkpoint{first_seq: 1, last_seq: 1, reason: "time"}] =
                 Receipts.checkpoints(scope)
      end)
    end

    test "a query row after the last checkpoint and before shutdown is covered by the shutdown checkpoint",
         %{scope: scope} do
      with_window(1_000, 60_000, fn ->
        {:ok, _} = Receipts.append(scope, query(1))
        {:ok, _} = Receipts.append(scope, query(2))
        :ok = Receipts.stop_writer(scope)

        assert [%Checkpoint{first_seq: 1, last_seq: 2, reason: "shutdown"}] =
                 Receipts.checkpoints(scope)
      end)
    end

    test "on rehydrate, uncovered query rows are checkpointed before a new row is accepted", %{
      scope: scope
    } do
      with_window(1_000, 60_000, fn ->
        {:ok, pid} = Receipts.ensure_writer(scope)
        {:ok, _} = Receipts.append(scope, query(1))
        # A crash, not a shutdown: terminate/2 does not run, nothing is covered, and the
        # writer is temporary, so nothing restarts it until the next demand.
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
        # The registry drops the name a moment after the DOWN; wait for that, not for luck.
        assert Enum.any?(1..50, fn _ ->
                 ChainWriter.whereis(scope) == nil || (Process.sleep(10) && false)
               end)

        assert Receipts.checkpoints(scope) == []
        {:ok, _} = Receipts.ensure_writer(scope)
        # The rehydrate checkpoint is written in the writer's continue, before this append is
        # served; the append's answer is the proof of the order.
        {:ok, %Receipt{seq: 2}} = Receipts.append(scope, query(2))

        assert [%Checkpoint{first_seq: 1, last_seq: 1, reason: "rehydrate"}] =
                 Receipts.checkpoints(scope)
      end)
    end
  end

  describe "refusals on start" do
    test "a tail altered on disk stops the writer with the reason", %{scope: scope} do
      {:ok, _} = Receipts.append(scope, decision(1))
      :ok = Receipts.stop_writer(scope)
      tail = Receipts.tail(scope)

      RRepo.update_all(from(r in Receipt, where: r.id == ^tail.id),
        set: [signed_payload: String.replace(tail.signed_payload, "allow", "deny!")]
      )

      Process.flag(:trap_exit, true)

      assert {:error, {:chain_inconsistent, ^scope, {:tail_hash_mismatch, 1}}} =
               ChainWriter.start_link(scope)
    end

    test "a checkpoint whose tail is not in the chain, or whose signature fails, stops the writer",
         %{scope: scope} do
      with_window(1, 60_000, fn ->
        {:ok, _} = Receipts.append(scope, query(1))
        [cp] = Receipts.checkpoints(scope)
        :ok = Receipts.stop_writer(scope)
        Process.flag(:trap_exit, true)

        RRepo.update_all(from(c in Checkpoint, where: c.id == ^cp.id),
          set: [tail_hash: String.duplicate("0", 64)]
        )

        assert {:error, {:chain_inconsistent, ^scope, {:checkpoint_tail_not_in_chain, 1}}} =
                 ChainWriter.start_link(scope)

        RRepo.update_all(from(c in Checkpoint, where: c.id == ^cp.id),
          set: [tail_hash: cp.tail_hash, signature: :crypto.strong_rand_bytes(64)]
        )

        assert {:error, {:chain_inconsistent, ^scope, {:checkpoint_signature_invalid, 1}}} =
                 ChainWriter.start_link(scope)
      end)
    end
  end

  test "the census: ChainWriter is the only inserter into receipts; the planted bypass is named" do
    {out, 0} = System.cmd("git", ["ls-files", "lib/*.ex", "test/support/*.ex"])
    files = out |> String.split("\n", trim: true)
    assert length(files) > 50

    # Slice 026 split this in two. The property slice 024 cared about is that nothing but the
    # writer brings a chain row into existence or removes one, and that is stated here directly.
    # The outbound queue (slice 026) writes through the same Repo, to `receipt_queue`, and only
    # ever updates a row it did not create; lumping it in with the inserters would have meant
    # either a false failure or widening the census until it no longer said anything.
    creates = ~w(insert insert! insert_all delete delete_all)
    mutates = creates ++ ~w(update update_all)

    callers = fn src, funs ->
      aliases =
        Regex.scan(~r/alias Trinity\.Repo\.Receipts(?:, as: ([A-Z]\w*))?/, src)
        |> Enum.map(fn
          [_, as] -> as
          [_] -> "Receipts"
        end)

      names = ["Trinity.Repo.Receipts" | aliases]

      Enum.any?(names, fn n ->
        Enum.any?(funs, &String.contains?(src, n <> "." <> &1 <> "("))
      end)
    end

    inserters = for f <- files, callers.(File.read!(f), creates), do: f
    writers = for f <- files, callers.(File.read!(f), mutates), do: f

    assert Enum.sort(inserters) == [
             "lib/trinity/receipts/chain_writer.ex",
             "test/support/receipts/bypass_inserter.ex"
           ],
           "something other than the ChainWriter creates or removes rows through the receipts Repo"

    assert Enum.sort(writers) == [
             "lib/trinity/receipts/chain_writer.ex",
             "lib/trinity/receipts/queue.ex",
             "test/support/receipts/bypass_inserter.ex"
           ],
           "a new writer appeared through the receipts Repo"

    # And the queue writes its own table only. It never names the chain's schemas in a write.
    queue_src = File.read!("lib/trinity/receipts/queue.ex")

    for fun <- mutates do
      refute queue_src =~ ~r/Repo\.#{fun}\(\s*%(Receipt|Checkpoint)\{/,
             "the queue writes a chain schema through #{fun}"
    end

    assert queue_src =~ "QueueEntry"

    assert Trinity.TestReceipts.BypassInserter in (:application.get_key(:trinity, :modules)
                                                   |> elem(1))
  end

  test "the scheme string resolves for every row and the implementations agree with the registry" do
    %{impl: impl, scheme: scheme} = KeyCustody.selected()
    assert {:ok, ^impl} = Signer.impl_for_scheme(scheme)
  end
end
