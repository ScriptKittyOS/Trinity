# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Verifier do
  @moduledoc """
  Walks one scope's chain and says whether it verifies (slice 024, AC3, AC7, AC8). Pure:
  it takes the rows, the checkpoints and the registry as plain maps (the export format, so
  the in-app task and the standalone `bin/verify_receipt.exs` run the same code), and uses
  `:crypto` and nothing else.

  For each receipt in seq order: the seq is the previous plus one; `prev_hash` is the
  previous `receipt_hash`; the scheme is one this verifier was told to accept (RFC 8725
  section 3.1: the caller names the allowed set); the key id resolves in the registry and the
  registry row's algorithm is the one the scheme names, else the receipt is refused before
  any signature is checked (SLICE.md amendments 3 and 4); the row's status is not
  `compromised`; the hash recomputes from the stored body through the PAE; a signed kind's
  signature verifies with the registry's public key under the registry's algorithm. Every
  query receipt must be covered by a checkpoint whose tail hash is in the chain and whose
  signature verifies the same way; a covered range never has a gap.

  Outcomes carry the exit vocabulary the operator learns once: `0` verified, `1` invalid,
  `2` usage, `5` trust not established (a key id the registry does not know), `6` a key the
  registry marks compromised.
  """

  alias Trinity.Receipts.{Envelope, Signer}

  @type outcome ::
          {:ok, %{receipts: non_neg_integer(), checkpoints: non_neg_integer()}}
          | {:error, code :: 1 | 5 | 6, reason :: term()}

  @signed_kinds ~w(decision effect boot cap)

  @doc "Exit code for an outcome."
  @spec exit_code(outcome()) :: 0 | 1 | 5 | 6
  def exit_code({:ok, _}), do: 0
  def exit_code({:error, code, _}), do: code

  @doc """
  Verifies an export map (`receipts`, `checkpoints`, `registry`). `opts`: `schemes:` the
  allowed scheme strings (all three by default); `require_coverage:` whether every query
  receipt needs a checkpoint (true by default; the writer covers the tail on shutdown and
  rehydrate, so an export taken mid-window may carry uncovered rows and the caller says so).
  """
  @spec verify(map(), keyword()) :: outcome()
  def verify(export, opts \\ [])

  def verify(
        %{"receipts" => receipts, "checkpoints" => checkpoints, "registry" => registry},
        opts
      ) do
    schemes =
      Keyword.get(opts, :schemes, Enum.map(Signer.algorithms(), &Signer.impl(&1).scheme()))

    require_coverage = Keyword.get(opts, :require_coverage, true)

    with :ok <- walk(receipts, registry, schemes),
         :ok <- check_checkpoints(checkpoints, receipts, registry, schemes),
         :ok <- check_coverage(receipts, checkpoints, require_coverage) do
      {:ok, %{receipts: length(receipts), checkpoints: length(checkpoints)}}
    end
  end

  def verify(_, _), do: {:error, 1, :not_an_export}

  ## The chain

  defp walk(receipts, registry, schemes) do
    receipts
    |> Enum.sort_by(& &1["seq"])
    |> Enum.reduce_while({:ok, 0, nil}, fn r, {:ok, prev_seq, prev_hash} ->
      case check_receipt(r, prev_seq, prev_hash, registry, schemes) do
        :ok -> {:cont, {:ok, r["seq"], r["receipt_hash"]}}
        {:error, _, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp check_receipt(r, prev_seq, prev_hash, registry, schemes) do
    seq = r["seq"]

    with :ok <- expect(seq == prev_seq + 1, 1, {:seq_gap, prev_seq, seq}),
         :ok <- expect(r["prev_hash"] == prev_hash, 1, {:prev_hash_mismatch, seq}),
         {:ok, impl, row} <- resolve(r["scheme"], r["key_id"], registry, schemes, seq),
         bytes = Envelope.pae(Envelope.receipt_type(r["scheme"]), r["signed_payload"]),
         :ok <- expect(Envelope.hash(bytes) == r["receipt_hash"], 1, {:hash_mismatch, seq}),
         :ok <- body_matches(r, seq) do
      if r["kind"] in @signed_kinds do
        with {:ok, sig} <- decode_sig(r["signature_b64"], seq),
             {:ok, pub} <- public_key(row, r["key_id"]) do
          expect(impl.verify(bytes, sig, pub), 1, {:signature_invalid, seq})
        end
      else
        :ok
      end
    end
  end

  # The stored body must say what the row says: a row whose columns disagree with its
  # signed body is a row edited after the fact.
  defp body_matches(r, seq) do
    case JSON.decode(r["signed_payload"]) do
      {:ok, body} ->
        expect(
          body["seq"] == r["seq"] and body["prev_hash"] == r["prev_hash"] and
            body["scheme"] == r["scheme"] and body["kind"] == r["kind"] and
            body["key_id"] == r["key_id"] and body["chain_scope"] == r["chain_scope"],
          1,
          {:body_column_mismatch, seq}
        )

      _ ->
        {:error, 1, {:body_not_json, seq}}
    end
  end

  # The algorithm comes from the registry row and nowhere else. A scheme the caller did not
  # allow, or a scheme naming another family than the key's row, is refused here, before
  # the signature is looked at.
  defp resolve(scheme, key_id, registry, schemes, seq) do
    with :ok <- expect(scheme in schemes, 1, {:scheme_not_allowed, seq, scheme}),
         {:ok, impl} <-
           Signer.impl_for_scheme(scheme) |> or_error({:error, 1, {:unknown_scheme, seq, scheme}}),
         %{} = row <- lookup(registry, key_id) || {:error, 5, {:unknown_key_id, seq, key_id}},
         :ok <- expect(row["status"] != "compromised", 6, {:key_compromised, seq, key_id}),
         :ok <-
           expect(
             row["algorithm"] == Atom.to_string(impl.algorithm()),
             1,
             {:scheme_family_mismatch, seq, scheme, row["algorithm"]}
           ) do
      {:ok, impl, row}
    end
  end

  ## Checkpoints

  defp check_checkpoints(checkpoints, receipts, registry, schemes) do
    by_seq = Map.new(receipts, &{&1["seq"], &1})

    Enum.reduce_while(checkpoints, :ok, fn cp, :ok ->
      case check_checkpoint(cp, by_seq, registry, schemes) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp check_checkpoint(cp, by_seq, registry, schemes) do
    last = cp["last_seq"]

    with %{} = tail <- by_seq[last] || {:error, 1, {:checkpoint_tail_missing, last}},
         :ok <-
           expect(tail["receipt_hash"] == cp["tail_hash"], 1, {:checkpoint_tail_mismatch, last}),
         :ok <-
           expect(
             is_integer(cp["first_seq"]) and cp["first_seq"] <= last,
             1,
             {:checkpoint_range, last}
           ),
         {:ok, impl, row} <-
           resolve(cp["scheme"], cp["key_id"], registry, schemes, {:checkpoint, last}),
         {:ok, body} <-
           JSON.decode(cp["signed_payload"])
           |> or_error({:error, 1, {:checkpoint_body_not_json, last}}),
         :ok <-
           expect(
             body["last_seq"] == last and body["first_seq"] == cp["first_seq"] and
               body["tail_hash"] == cp["tail_hash"],
             1,
             {:checkpoint_body_mismatch, last}
           ),
         {:ok, sig} <- decode_sig(cp["signature_b64"], {:checkpoint, last}),
         {:ok, pub} <- public_key(row, cp["key_id"]) do
      bytes = Envelope.pae(Envelope.checkpoint_type(cp["scheme"]), cp["signed_payload"])
      expect(impl.verify(bytes, sig, pub), 1, {:checkpoint_signature_invalid, last})
    end
  end

  defp check_coverage(_receipts, _checkpoints, false), do: :ok

  defp check_coverage(receipts, checkpoints, true) do
    covered =
      Enum.flat_map(checkpoints, fn cp -> Enum.to_list(cp["first_seq"]..cp["last_seq"]//1) end)
      |> MapSet.new()

    uncovered =
      receipts
      |> Enum.filter(&(&1["kind"] == "query" and not MapSet.member?(covered, &1["seq"])))
      |> Enum.map(& &1["seq"])

    expect(uncovered == [], 1, {:query_receipts_uncovered, uncovered})
  end

  ## Helpers

  defp lookup(registry, key_id) when is_list(registry) and is_binary(key_id),
    do: registry |> Enum.filter(&(&1["key_id"] == key_id)) |> List.last()

  defp lookup(_, _), do: nil

  defp public_key(%{"public_key_b64" => b64}, key_id) do
    Base.decode64(b64) |> or_error({:error, 5, {:key_undecodable, key_id}})
  end

  defp public_key(_, key_id), do: {:error, 5, {:key_without_public, key_id}}

  defp decode_sig(nil, seq), do: {:error, 1, {:signature_missing, seq}}

  defp decode_sig(b64, seq),
    do: Base.decode64(b64) |> or_error({:error, 1, {:signature_undecodable, seq}})

  defp expect(true, _code, _reason), do: :ok
  defp expect(false, code, reason), do: {:error, code, reason}

  defp or_error({:ok, v}, _), do: {:ok, v}
  defp or_error(:error, e), do: e
  defp or_error({:error, _}, e), do: e
end
