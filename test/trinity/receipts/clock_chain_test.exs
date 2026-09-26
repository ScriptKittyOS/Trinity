# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.ClockChainTest do
  @moduledoc """
  Slice 026: the clock in a real chain, and the scheme bump that carries it.

  The clock is in the **signed** payload, not in `meta`. That is the decision this file exists to
  hold in place: a merge that orders two chains by an unsigned field orders them by something any
  writer could rewrite afterwards, which would make the merge evidence of nothing. The cost is a
  scheme bump, and the bump has to leave every row signed under the old scheme verifiable, which is
  the other half of what is asserted here.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts
  alias Trinity.Receipts.{Clock, Envelope, KeyCustody, Receipt, Signer, Verifier}

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

  # `stop_writer/1` returns before the process is gone, so an append straight after it can reach a
  # dying pid through the registry and exit with :noproc. `chain_writer_test.exs` already waits the
  # same way; this test did not, and failed 2 runs in 3 until it did.
  defp await_stopped(scope) do
    if Trinity.Receipts.ChainWriter.whereis(scope) do
      Process.sleep(10)
      await_stopped(scope)
    else
      :ok
    end
  end

  defp clock_of(%Receipt{signed_payload: payload}) do
    {:ok, body} = JSON.decode(payload)
    {:ok, clock} = Clock.from_map(body["clock"])
    clock
  end

  describe "AC1 (the clock half): every receipt carries one, and it only goes forward" do
    test "every row of a chain carries a clock in its signed payload", %{scope: scope} do
      for n <- 1..5, do: {:ok, _} = Receipts.append(scope, decision(n))

      for row <- Receipts.list(scope) do
        {:ok, body} = JSON.decode(row.signed_payload)

        assert {:ok, %Clock{}} = Clock.from_map(body["clock"]),
               "row #{row.seq} carries no clock: #{inspect(body["clock"])}"
      end
    end

    test "the clocks are strictly increasing along the chain", %{scope: scope} do
      for n <- 1..8, do: {:ok, _} = Receipts.append(scope, decision(n))

      clocks = scope |> Receipts.list() |> Enum.map(&clock_of/1)

      clocks
      |> Enum.zip(tl(clocks))
      |> Enum.each(fn {a, b} ->
        assert Clock.compare(b, a) == :gt,
               "clock did not advance between rows: #{inspect(a)} then #{inspect(b)}"
      end)
    end

    test "every row names this device", %{scope: scope} do
      {:ok, row} = Receipts.append(scope, decision(1))
      assert clock_of(row).node == Clock.node_id()
    end

    test "a chain survives a writer restart with its clock intact", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      before = scope |> Receipts.list() |> List.last() |> clock_of()

      :ok = Receipts.stop_writer(scope)
      :ok = await_stopped(scope)
      {:ok, _} = Receipts.append(scope, decision(4))

      after_restart = scope |> Receipts.list() |> List.last() |> clock_of()

      assert Clock.compare(after_restart, before) == :gt,
             "the writer rehydrated without reading the tail's clock, so the chain's clock " <>
               "restarted and a row now appears to precede one already written"
    end
  end

  describe "the clock is signed, not decoration" do
    test "editing the clock in a stored payload breaks verification", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      :ok = Receipts.stop_writer(scope)
      {:ok, export} = Receipts.export(scope)

      assert {:ok, _} = Verifier.verify(export)

      tampered =
        update_in(export["receipts"], fn rows ->
          Enum.map(rows, fn r ->
            {:ok, body} = JSON.decode(r["signed_payload"])

            if body["seq"] == 2 do
              moved = %{body | "clock" => %{body["clock"] | "wall" => 0}}
              %{r | "signed_payload" => Jcs.encode(moved)}
            else
              r
            end
          end)
        end)

      assert {:error, _, _} = Verifier.verify(tampered),
             "the clock was moved and the chain still verified. If the clock can be edited " <>
               "after the fact then ordering two chains by it proves nothing."
    end
  end

  describe "AC3: a clock that does not follow the tail is refused, and the refusal is receipted" do
    test "the offered clock is behind the chain tail", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      tail_clock = scope |> Receipts.list() |> List.last() |> clock_of()

      behind = %Clock{tail_clock | wall: tail_clock.wall - 1_000}

      assert {:error, {:clock_regression, _offered, _held}} =
               Receipts.append(scope, Map.put(decision(99), :clock, behind))
    end

    test "the refusal is itself a receipt on the chain, naming both clocks", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      tail_clock = scope |> Receipts.list() |> List.last() |> clock_of()
      behind = %Clock{tail_clock | wall: tail_clock.wall - 1_000}

      {:error, _} = Receipts.append(scope, Map.put(decision(99), :clock, behind))

      refusal =
        scope
        |> Receipts.list()
        |> Enum.find(
          &(&1.subject_ref && String.starts_with?(&1.subject_ref, "clock_regression:"))
        )

      assert refusal,
             "a receipt was refused and nothing recorded it. A refusal that leaves no record is " <>
               "indistinguishable from the call never having been made."

      {:ok, body} = JSON.decode(refusal.signed_payload)
      assert get_in(body, ["decision", "outcome"]) == "refused"
      assert get_in(body, ["decision", "basis"]) == "clock"
      assert get_in(body, ["subject", "offered_clock", "wall"]) == behind.wall
      assert get_in(body, ["subject", "held_clock", "wall"]) == tail_clock.wall
    end

    test "the refused row is not in the chain, and the chain still verifies", %{scope: scope} do
      for n <- 1..3, do: {:ok, _} = Receipts.append(scope, decision(n))
      tail_clock = scope |> Receipts.list() |> List.last() |> clock_of()
      behind = %Clock{tail_clock | wall: tail_clock.wall - 1_000}

      {:error, _} = Receipts.append(scope, Map.put(decision(99), :clock, behind))

      refute Enum.any?(Receipts.list(scope), fn r ->
               {:ok, body} = JSON.decode(r.signed_payload)
               body["fingerprint"] == "ab99"
             end),
             "the refused receipt was written anyway"

      :ok = Receipts.stop_writer(scope)
      {:ok, export} = Receipts.export(scope)
      assert {:ok, _} = Verifier.verify(export)
    end

    test "an equal clock is refused too: a row must follow, not tie", %{scope: scope} do
      {:ok, _} = Receipts.append(scope, decision(1))
      tail_clock = scope |> Receipts.list() |> List.last() |> clock_of()

      assert {:error, {:clock_regression, _, _}} =
               Receipts.append(scope, Map.put(decision(2), :clock, tail_clock))
    end
  end

  describe "the scheme bump is a bump, not an edit" do
    test "new rows are written under the current version", %{scope: scope} do
      {:ok, row} = Receipts.append(scope, decision(1))
      assert {:ok, version, _family} = Signer.parse_scheme(row.scheme)
      assert version == Signer.current_scheme_version()
      assert Signer.clocked?(row.scheme)
    end

    test "both versions resolve to the same signer family" do
      for a <- Signer.algorithms() do
        v2 = "receipt_v2_#{a}"
        v3 = "receipt_v3_#{a}"
        assert Signer.impl_for_scheme(v2) == Signer.impl_for_scheme(v3)
      end
    end

    test "v2 is readable and carries no clock; v3 carries one" do
      refute Signer.clocked?("receipt_v2_ed25519")
      assert Signer.clocked?("receipt_v3_ed25519")
      assert "receipt_v2_ed25519" in Signer.accepted_schemes()
      assert "receipt_v3_ed25519" in Signer.accepted_schemes()
    end

    test "no signer family contains an underscore, which is what makes parsing the scheme safe" do
      for a <- Signer.algorithms() do
        refute Atom.to_string(a) =~ "_",
               "#{a} contains an underscore, so receipt_<version>_<family> can no longer be " <>
                 "split into two parts and Signer.parse_scheme/1 is wrong"
      end
    end

    test "a row signed under v2 still verifies after the bump", %{scope: scope} do
      # Built by hand because the writer only ever writes the current version. This is the whole
      # claim of a scheme bump: bytes signed last week still verify this week.
      %{scheme: current, key_id: key_id} = KeyCustody.selected()
      {:ok, _version, family} = Signer.parse_scheme(current)
      v2_scheme = "receipt_v2_#{family}"

      body = %{
        "scheme" => v2_scheme,
        "seq" => 1,
        "chain_scope" => scope,
        "prev_hash" => nil,
        "kind" => "decision",
        "subject" => %{"n" => 1},
        "decision" => %{"outcome" => "allow"},
        "fingerprint" => "ab01",
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "key_id" => key_id
      }

      payload = Envelope.canonical(body)
      bytes = Envelope.pae(Envelope.receipt_type(v2_scheme), payload)
      {:ok, signature} = KeyCustody.sign(bytes)

      {:ok, registry} = Trinity.Receipts.KeyRegistry.read(KeyCustody.keys_dir())

      export = %{
        "format" => "trinity-receipts-export/1",
        "chain_scope" => scope,
        "receipts" => [
          %{
            "seq" => 1,
            "prev_hash" => nil,
            "receipt_hash" => Envelope.hash(bytes),
            "scheme" => v2_scheme,
            "kind" => "decision",
            "chain_scope" => scope,
            "key_id" => key_id,
            "signed_payload" => payload,
            "signature_b64" => Base.encode64(signature)
          }
        ],
        "checkpoints" => [],
        "registry" => registry
      }

      assert {:ok, %{receipts: 1}} = Verifier.verify(export),
             "a row signed under the previous scheme no longer verifies. That makes the version " <>
               "change an edit to history rather than a bump."
    end
  end
end
