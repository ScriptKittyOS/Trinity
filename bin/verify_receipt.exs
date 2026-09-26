#!/usr/bin/env elixir
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Verifies an exported Trinity receipt chain with nothing but Elixir and OTP's :crypto
# (slice 024, AC7). Run it from any directory against a file `mix trinity.receipts.export`
# wrote; the registry travels inside the file.
#
#   elixir verify_receipt.exs receipts.json [--schemes receipt_v3_ed25519,receipt_v2_ed25519]
#
# Exit codes, the vocabulary an operator learns once: 0 verified, 1 invalid, 2 usage,
# 5 trust not established (a key id the registry does not know), 6 compromised key.
#
# This is a copy of Trinity.Receipts.Verifier's rules, kept small so a stranger can read it:
# the seq is the previous plus one; prev_hash is the previous receipt_hash; the scheme is
# allowed; the key id resolves in the registry and the row's algorithm is the scheme's family,
# else refused before any signature check; the row is not compromised; the hash recomputes
# over DSSE's PAE of "trinity/receipt/<scheme>" and the stored body; decision, effect, boot
# and cap receipts carry a signature that verifies under the registry's algorithm; every
# query receipt is covered by a checkpoint whose tail is in the chain and whose signature
# verifies the same way. test/trinity/receipts/standalone_verifier_test.exs asserts this
# file and the in-app verifier agree on the same inputs.

defmodule VerifyReceipt do
  # Every scheme version this script can read. `v2` is slice 024's; `v3` is slice 026's and carries
  # a hybrid logical clock in the signed payload. Both are listed because a chain that spans the
  # bump has rows of each, and dropping the older one would mean a verifier that refuses bytes it
  # signed itself last week.
  @families %{
    "receipt_v2_ed25519" => {"ed25519", :eddsa, :none, :ed25519},
    "receipt_v2_p384" => {"p384", :ecdsa, :sha384, :secp384r1},
    "receipt_v2_mldsa87" => {"mldsa87", :mldsa87, :none, nil},
    "receipt_v3_ed25519" => {"ed25519", :eddsa, :none, :ed25519},
    "receipt_v3_p384" => {"p384", :ecdsa, :sha384, :secp384r1},
    "receipt_v3_mldsa87" => {"mldsa87", :mldsa87, :none, nil}
  }
  @signed_kinds ~w(decision effect boot cap)

  def main(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [schemes: :string])

    case args do
      [path] ->
        schemes =
          case opts[:schemes] do
            nil -> Map.keys(@families)
            s -> String.split(s, ",", trim: true)
          end

        case File.read(path) do
          {:ok, bin} -> run(JSON.decode(bin), schemes)
          {:error, reason} -> usage("cannot read #{path}: #{inspect(reason)}")
        end

      _ ->
        usage("usage: elixir verify_receipt.exs <export.json> [--schemes a,b]")
    end
  end

  defp usage(msg) do
    IO.puts(:stderr, msg)
    System.halt(2)
  end

  defp run({:ok, %{"receipts" => rs, "checkpoints" => cps, "registry" => reg}}, schemes) do
    result =
      with :ok <- walk(Enum.sort_by(rs, & &1["seq"]), reg, schemes, 0, nil),
           :ok <- checkpoints(cps, Map.new(rs, &{&1["seq"], &1}), reg, schemes),
           :ok <- coverage(rs, cps) do
        {:ok, length(rs), length(cps)}
      end

    case result do
      {:ok, n, c} ->
        IO.puts("verified: #{n} receipts, #{c} checkpoints")
        System.halt(0)

      {:error, code, reason} ->
        IO.puts(:stderr, "#{label(code)}: #{inspect(reason)}")
        System.halt(code)
    end
  end

  defp run(_, _), do: usage("not a receipts export")

  defp label(1), do: "invalid"
  defp label(5), do: "trust not established"
  defp label(6), do: "compromised key"

  defp walk([], _reg, _schemes, _seq, _hash), do: :ok

  defp walk([r | rest], reg, schemes, prev_seq, prev_hash) do
    seq = r["seq"]

    with :ok <- expect(seq == prev_seq + 1, 1, {:seq_gap, prev_seq, seq}),
         :ok <- expect(r["prev_hash"] == prev_hash, 1, {:prev_hash_mismatch, seq}),
         {:ok, fam, row} <- resolve(r["scheme"], r["key_id"], reg, schemes, seq),
         bytes = pae("trinity/receipt/" <> r["scheme"], r["signed_payload"]),
         :ok <- expect(hash(bytes) == r["receipt_hash"], 1, {:hash_mismatch, seq}),
         :ok <- body_matches(r, seq),
         :ok <- signature(r, bytes, fam, row, seq) do
      walk(rest, reg, schemes, seq, r["receipt_hash"])
    end
  end

  defp signature(r, bytes, fam, row, seq) do
    if r["kind"] in @signed_kinds do
      with {:ok, sig} <- b64(r["signature_b64"], 1, {:signature_undecodable, seq}),
           {:ok, pub} <- b64(row["public_key_b64"], 5, {:key_undecodable, r["key_id"]}) do
        expect(verify(fam, bytes, sig, pub), 1, {:signature_invalid, seq})
      end
    else
      :ok
    end
  end

  defp body_matches(r, seq) do
    case JSON.decode(r["signed_payload"]) do
      {:ok, b} ->
        expect(
          b["seq"] == r["seq"] and b["prev_hash"] == r["prev_hash"] and b["scheme"] == r["scheme"] and
            b["kind"] == r["kind"] and b["key_id"] == r["key_id"] and b["chain_scope"] == r["chain_scope"],
          1,
          {:body_column_mismatch, seq}
        )

      _ ->
        {:error, 1, {:body_not_json, seq}}
    end
  end

  defp resolve(scheme, key_id, reg, schemes, seq) do
    with :ok <- expect(scheme in schemes, 1, {:scheme_not_allowed, seq, scheme}),
         {:ok, fam} <- Map.fetch(@families, scheme) |> or_error({:error, 1, {:unknown_scheme, seq, scheme}}),
         %{} = row <- lookup(reg, key_id) || {:error, 5, {:unknown_key_id, seq, key_id}},
         :ok <- expect(row["status"] != "compromised", 6, {:key_compromised, seq, key_id}),
         :ok <- expect(row["algorithm"] == elem(fam, 0), 1, {:scheme_family_mismatch, seq, scheme, row["algorithm"]}) do
      {:ok, fam, row}
    end
  end

  defp checkpoints(cps, by_seq, reg, schemes) do
    Enum.reduce_while(cps, :ok, fn cp, :ok ->
      last = cp["last_seq"]

      r =
        with %{} = tail <- by_seq[last] || {:error, 1, {:checkpoint_tail_missing, last}},
             :ok <- expect(tail["receipt_hash"] == cp["tail_hash"], 1, {:checkpoint_tail_mismatch, last}),
             :ok <- expect(is_integer(cp["first_seq"]) and cp["first_seq"] <= last, 1, {:checkpoint_range, last}),
             {:ok, fam, row} <- resolve(cp["scheme"], cp["key_id"], reg, schemes, {:checkpoint, last}),
             {:ok, body} <- JSON.decode(cp["signed_payload"]) |> or_error({:error, 1, {:checkpoint_body_not_json, last}}),
             :ok <- expect(body["last_seq"] == last and body["first_seq"] == cp["first_seq"] and body["tail_hash"] == cp["tail_hash"], 1, {:checkpoint_body_mismatch, last}),
             {:ok, sig} <- b64(cp["signature_b64"], 1, {:signature_undecodable, {:checkpoint, last}}),
             {:ok, pub} <- b64(row["public_key_b64"], 5, {:key_undecodable, cp["key_id"]}) do
          expect(verify(fam, pae("trinity/checkpoint/" <> cp["scheme"], cp["signed_payload"]), sig, pub), 1, {:checkpoint_signature_invalid, last})
        end

      if r == :ok, do: {:cont, :ok}, else: {:halt, r}
    end)
  end

  defp coverage(rs, cps) do
    covered = cps |> Enum.flat_map(fn cp -> Enum.to_list(cp["first_seq"]..cp["last_seq"]//1) end) |> MapSet.new()
    uncovered = rs |> Enum.filter(&(&1["kind"] == "query" and not MapSet.member?(covered, &1["seq"]))) |> Enum.map(& &1["seq"])
    expect(uncovered == [], 1, {:query_receipts_uncovered, uncovered})
  end

  defp verify({_, :eddsa, _, curve}, bytes, sig, pub), do: :crypto.verify(:eddsa, :none, bytes, sig, [pub, curve])
  defp verify({_, :ecdsa, digest, curve}, bytes, sig, pub), do: :crypto.verify(:ecdsa, digest, bytes, sig, [pub, curve])
  defp verify({_, :mldsa87, _, _}, bytes, sig, pub), do: :crypto.verify(:mldsa87, :none, bytes, sig, pub)

  defp pae(type, body),
    do: "DSSEv1 " <> Integer.to_string(byte_size(type)) <> " " <> type <> " " <> Integer.to_string(byte_size(body)) <> " " <> body

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp lookup(reg, key_id) when is_list(reg) and is_binary(key_id), do: reg |> Enum.filter(&(&1["key_id"] == key_id)) |> List.last()
  defp lookup(_, _), do: nil

  defp b64(nil, code, reason), do: {:error, code, reason}
  defp b64(s, code, reason), do: Base.decode64(s) |> or_error({:error, code, reason})

  defp expect(true, _, _), do: :ok
  defp expect(false, code, reason), do: {:error, code, reason}

  defp or_error({:ok, v}, _), do: {:ok, v}
  defp or_error(_, e), do: e
end

VerifyReceipt.main(System.argv())
