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
  signature verifies with the registry's public key under the registry's algorithm; and, since
  slice 100, a receipt under a key the registry marks `retired` is dated (its signed `at`) no
  later than that row's `valid_until`. The last check is as strong as the clock the receipt was
  written by and no stronger: whoever holds a retired key can sign a backdated body. It stops a
  retired key's receipts from being minted after the rotation by anything that keeps honest time,
  and it makes `valid_until` a field something reads rather than a note. Every
  query receipt must be covered by a checkpoint whose tail hash is in the chain and whose
  signature verifies the same way; a covered range never has a gap.

  Since slice 140 a row or checkpoint under a `v4` scheme is an N6 statement, checked by
  `Trinity.Receipts.V4` with the same registry resolution first: its `receipt_hash` is its
  `statement_id`, its `prev_hash` its predecessor's link id (a `v2` or `v3` predecessor's is SHA-384
  over its PAE bytes), its body is strictly decoded under its kind's schema and must say what the
  columns say, and a signed kind's carrier verifies under the registered key at the entry point
  (`entry:`, `:commercial` by default). The bytes of `subject` and `decision` are checked against the
  ForeignRefs the signed body holds; a missing or mismatched attachment is a finding, returned beside
  the verdict, and never changes it, because those bytes are not what the signature covers.

  Outcomes carry the exit vocabulary the operator learns once: `0` verified, `1` invalid,
  `2` usage, `5` trust not established (a key id the registry does not know, or, since slice 139,
  a signature this runtime cannot judge: an algorithm it refuses, as FIPS mode refuses Ed25519, or
  a registered key it cannot use), `6` a key the registry marks compromised, and, since slice 144,
  `7` accuse: a v4 row or checkpoint whose signature verifies under its registered key over bytes
  that break the profile's rules (`{:accuse, at, verdict_code, [{:nonconforming, code}]}`).

  Since slice 144 the chain's crossing from the earlier formats is reported: the first v4 row after
  a v2 or v3 row adds the finding `{:crossing, seq}`, and a v2 or v3 row after a v4 row is refused
  (`{:legacy_after_n6, seq}`, exit 1), because a chain crosses once (N6 draft v0.1-r7 section 3.9).
  Both names are this tree's until the profile names them (its VB3).
  """

  alias Trinity.Receipts.{Envelope, Signer, V4}

  @type outcome ::
          {:ok,
           %{receipts: non_neg_integer(), checkpoints: non_neg_integer(), findings: [tuple()]}}
          | {:error, code :: 1 | 5 | 6 | 7, reason :: term()}

  @signed_kinds ~w(decision effect boot cap)

  @doc "Exit code for an outcome."
  @spec exit_code(outcome()) :: 0 | 1 | 5 | 6 | 7
  def exit_code({:ok, _}), do: 0
  def exit_code({:error, code, _}), do: code

  @doc """
  Verifies an export map (`receipts`, `checkpoints`, `registry`). `opts`: `schemes:` the
  allowed scheme strings (all three by default); `require_coverage:` whether every query
  receipt needs a checkpoint (true by default; the writer covers the tail on shutdown and
  rehydrate, so an export taken mid-window may carry uncovered rows and the caller says so);
  `entry:` the N6 entry point for v4 rows (`:commercial` by default); `issuer:` the issuer every v4
  body must name (the export's `issuer` by default).
  """
  @spec verify(map(), keyword()) :: outcome()
  def verify(export, opts \\ [])

  def verify(
        %{"receipts" => receipts, "checkpoints" => checkpoints, "registry" => registry} = export,
        opts
      ) do
    schemes =
      Keyword.get(opts, :schemes, Signer.accepted_schemes())

    require_coverage = Keyword.get(opts, :require_coverage, true)

    n6 = [
      registry: registry,
      entry: Keyword.get(opts, :entry, :commercial),
      issuer: Keyword.get(opts, :issuer, export["issuer"])
    ]

    with {:ok, findings} <- walk(receipts, registry, schemes, n6),
         :ok <- check_checkpoints(checkpoints, receipts, registry, schemes, n6),
         :ok <- check_coverage(receipts, checkpoints, require_coverage) do
      {:ok, %{receipts: length(receipts), checkpoints: length(checkpoints), findings: findings}}
    end
  end

  def verify(_, _), do: {:error, 1, :not_an_export}

  ## The chain

  defp walk(receipts, registry, schemes, n6) do
    receipts
    |> Enum.sort_by(& &1["seq"])
    |> Enum.reduce_while({:ok, 0, nil, []}, fn r, {:ok, prev_seq, prev, findings} ->
      case check_any(r, prev_seq, prev, registry, schemes, n6) do
        {:ok, found} -> {:cont, {:ok, r["seq"], r, findings ++ found}}
        {:error, _, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, _, _, findings} -> {:ok, findings}
      error -> error
    end
  end

  # A v4 row is checked by `V4`, a v2 or v3 row as before. The predecessor is named by its link id
  # (a v4 row) or by its `receipt_hash` (a v2 or v3 row); `link/1` gives the former for either.
  defp check_any(r, prev_seq, prev, registry, schemes, n6) do
    cond do
      n6?(r) ->
        with {:ok, found} <- check_v4(r, prev_seq, prev, registry, schemes, n6),
             do: {:ok, crossing(r, prev) ++ found}

      prev != nil and n6?(prev) ->
        {:error, 1, {:legacy_after_n6, r["seq"]}}

      true ->
        with :ok <- check_receipt(r, prev_seq, prev && prev["receipt_hash"], registry, schemes),
             do: {:ok, []}
    end
  end

  defp n6?(r), do: Signer.n6?(r["scheme"] || "")

  # The one link from a v2 or v3 row to the first v4 row after it.
  defp crossing(_r, nil), do: []
  defp crossing(r, prev), do: if(n6?(prev), do: [], else: [{:crossing, r["seq"]}])

  defp check_v4(r, prev_seq, prev, registry, schemes, n6) do
    seq = r["seq"]

    with :ok <- expect(seq == prev_seq + 1, 1, {:seq_gap, prev_seq, seq}),
         {:ok, _impl, row} <- resolve(r["scheme"], r["key_id"], registry, schemes, seq),
         {:ok, info} <- v4_row(r, prev, n6),
         :ok <- within_validity_at(info.at, row, seq, r["key_id"]) do
      {:ok, info.findings}
    end
  end

  # The same reason a v3 row's bad signature gives, so an operator reads one vocabulary.
  defp v4_row(r, prev, n6) do
    case V4.verify_row(r, prev && link(prev), n6) do
      {:error, 1, {:n6, seq, :signature_invalid}} -> {:error, 1, {:signature_invalid, seq}}
      other -> other
    end
  end

  @doc """
  A row's link id, as the next v4 row names it: a v4 row's `statement_id` (its `receipt_hash`), or
  SHA-384 over a v2 or v3 row's PAE bytes.
  """
  @spec link(map()) :: binary()
  def link(r) do
    if Signer.n6?(r["scheme"] || "") do
      Base.decode16!(r["receipt_hash"], case: :lower)
    else
      V4.legacy_link(Envelope.pae(Envelope.receipt_type(r["scheme"]), r["signed_payload"]))
    end
  end

  # Slice 100's retired-key window, for a v4 row's signed `at` (microseconds since the epoch).
  defp within_validity_at(at, %{"status" => "retired", "valid_until" => until}, seq, key_id)
       when is_binary(until) and is_integer(at) do
    with {:ok, until, _} <- DateTime.from_iso8601(until),
         {:ok, at} <- DateTime.from_unix(at, :microsecond) do
      expect(DateTime.compare(at, until) != :gt, 1, {:key_retired, seq, key_id})
    else
      _ -> :ok
    end
  end

  defp within_validity_at(_at, _row, _seq, _key_id), do: :ok

  defp check_receipt(r, prev_seq, prev_hash, registry, schemes) do
    seq = r["seq"]

    with :ok <- expect(seq == prev_seq + 1, 1, {:seq_gap, prev_seq, seq}),
         :ok <- expect(r["prev_hash"] == prev_hash, 1, {:prev_hash_mismatch, seq}),
         {:ok, impl, row} <- resolve(r["scheme"], r["key_id"], registry, schemes, seq),
         bytes = Envelope.pae(Envelope.receipt_type(r["scheme"]), r["signed_payload"]),
         :ok <- expect(Envelope.hash(bytes) == r["receipt_hash"], 1, {:hash_mismatch, seq}),
         :ok <- body_matches(r, seq),
         :ok <- within_validity(r, row, seq) do
      check_signature(r, bytes, impl, row, seq)
    end
  end

  # Slice 100: a retired key signs nothing dated after its `valid_until`.
  defp within_validity(r, %{"status" => "retired", "valid_until" => until}, seq)
       when is_binary(until) do
    with {:ok, %{"at" => at}} when is_binary(at) <- JSON.decode(r["signed_payload"]),
         {:ok, at, _} <- DateTime.from_iso8601(at),
         {:ok, until, _} <- DateTime.from_iso8601(until) do
      expect(DateTime.compare(at, until) != :gt, 1, {:key_retired, seq, r["key_id"]})
    else
      _ -> :ok
    end
  end

  defp within_validity(_r, _row, _seq), do: :ok

  defp check_signature(%{"kind" => kind} = r, bytes, impl, row, seq) when kind in @signed_kinds do
    with {:ok, sig} <- decode_sig(r["signature_b64"], seq),
         {:ok, pub} <- public_key(row, r["key_id"]) do
      answer(
        Signer.check(impl, bytes, sig, pub),
        seq,
        impl,
        r["key_id"],
        {:signature_invalid, seq}
      )
    end
  end

  defp check_signature(_r, _bytes, _impl, _row, _seq), do: :ok

  # Slice 139: a runtime that refuses the row's algorithm, or cannot use its registered key, cannot
  # judge the signature. That is trust not established (5), naming where and why; before 139 it was
  # an exception out of `:crypto.verify`.
  defp answer(:ok, _at, _impl, _key_id, _invalid), do: :ok
  defp answer(:invalid, _at, _impl, _key_id, invalid), do: {:error, 1, invalid}

  defp answer(:alg_unavailable, at, impl, _key_id, _invalid),
    do: {:error, 5, {:alg_unavailable, at, Atom.to_string(impl.algorithm())}}

  defp answer(:key_unusable, _at, _impl, key_id, _invalid),
    do: {:error, 5, {:key_undecodable, key_id}}

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

  defp check_checkpoints(checkpoints, receipts, registry, schemes, n6) do
    by_seq = Map.new(receipts, &{&1["seq"], &1})

    Enum.reduce_while(checkpoints, :ok, fn cp, :ok ->
      case check_checkpoint(cp, by_seq, registry, schemes, n6) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp check_checkpoint(%{"body_b64" => _} = cp, by_seq, registry, schemes, n6) do
    last = cp["last_seq"]

    with %{} = tail <- by_seq[last] || {:error, 1, {:checkpoint_tail_missing, last}},
         :ok <-
           expect(
             is_integer(cp["first_seq"]) and cp["first_seq"] <= last,
             1,
             {:checkpoint_range, last}
           ),
         {:ok, _impl, _row} <-
           resolve(cp["scheme"], cp["key_id"], registry, schemes, {:checkpoint, last}) do
      case V4.verify_checkpoint(cp, link(tail), n6) do
        :ok ->
          :ok

        {:error, 1, {:checkpoint_body_mismatch, _}} ->
          {:error, 1, {:checkpoint_tail_mismatch, last}}

        {:error, 1, {:n6, at, :signature_invalid}} ->
          {:error, 1, {:checkpoint_signature_invalid, elem(at, 1)}}

        error ->
          error
      end
    end
  end

  defp check_checkpoint(cp, by_seq, registry, schemes, _n6) do
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

      answer(
        Signer.check(impl, bytes, sig, pub),
        {:checkpoint, last},
        impl,
        cp["key_id"],
        {:checkpoint_signature_invalid, last}
      )
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
