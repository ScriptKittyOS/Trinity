#!/usr/bin/env elixir
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Verifies an exported Trinity receipt chain with nothing but Elixir and OTP's :crypto
# (slice 024, AC7). Run it from any directory against a file `mix trinity.receipts.export`
# wrote; the registry travels inside the file.
#
#   elixir verify_receipt.exs receipts.json [--schemes receipt_v3_ed25519,receipt_v2_ed25519]
#                                           [--n6 <Trinity's lib directory>]
#
# Exit codes, the vocabulary an operator learns once: 0 verified, 1 invalid, 2 usage,
# 5 trust not established (a key id the registry does not know, or a signature this runtime
# cannot judge: an algorithm it refuses, or a registered key it cannot use), 6 compromised key.
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
#
# Slice 140: a v4 row or checkpoint is an N6 statement, and checking one needs a strict N6 decoder,
# far more than this file should hold. So for those this script loads, from source, the N6 files
# and Trinity.Receipts.V4, which depend on nothing but each other and :crypto, and runs the same
# rules the in-app verifier runs (V4.verify_row/3, V4.verify_checkpoint/3) after the same registry
# resolution as above. They are read from ../lib beside this file in a checkout, or from the
# directory --n6 names. A chain with no v4 row needs neither, and the script loads nothing. A
# finding about a v4 row's stored attachments (its subject or decision bytes missing or not what its
# signed body names) is printed after the verdict and does not change it.

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
    "receipt_v3_mldsa87" => {"mldsa87", :mldsa87, :none, nil},
    "receipt_v4_ed25519" => {"ed25519", :eddsa, :none, :ed25519},
    "receipt_v4_p384" => {"p384", :ecdsa, :sha384, :secp384r1},
    "receipt_v4_mldsa87" => {"mldsa87", :mldsa87, :none, nil}
  }
  @signed_kinds ~w(decision effect boot cap)

  # The sources a v4 row needs, relative to Trinity's lib directory, in the order they are loaded.
  @n6_sources ~w(n6/profile.ex n6/unicode15.ex n6/cbor.ex n6/digest.ex n6/body.ex n6/ec2.ex n6/ed25519.ex n6/cose.ex n6/carrier.ex receipts/v4.ex)

  # Named at run time, so compiling this file before the sources are loaded warns about nothing.
  defp v4, do: Module.concat(["Trinity", "Receipts", "V4"])

  def main(argv) do
    # OTP 28.5.0.8 warns on stdout when :crypto loads before its application ("Module 'crypto'
    # loaded without application 'crypto' being loaded"), which a plain `elixir` run does; loading
    # the application first keeps the verdict the only line (slice 140, measured on that runtime).
    _ = Application.load(:crypto)
    {opts, args, _} = OptionParser.parse(argv, strict: [schemes: :string, n6: :string])

    case args do
      [path] ->
        schemes =
          case opts[:schemes] do
            nil -> Map.keys(@families)
            s -> String.split(s, ",", trim: true)
          end

        case File.read(path) do
          {:ok, bin} -> bin |> JSON.decode() |> load_n6(opts[:n6]) |> run(schemes)
          {:error, reason} -> usage("cannot read #{path}: #{inspect(reason)}")
        end

      _ ->
        usage("usage: elixir verify_receipt.exs <export.json> [--schemes a,b] [--n6 <lib dir>]")
    end
  end

  defp load_n6({:ok, %{"receipts" => rs, "checkpoints" => cps}} = export, dir) do
    if Enum.any?(rs ++ cps, &n6?/1) do
      root = dir || Path.expand("../lib", __DIR__)
      files = Enum.map(@n6_sources, &Path.join([root, "trinity", &1]))

      case Enum.reject(files, &File.regular?/1) do
        [] -> Enum.each(files, &Code.require_file/1)
        _ -> usage("v4 rows need Trinity's N6 sources: --n6 <Trinity's lib directory> (#{root} has none)")
      end
    end

    export
  end

  defp load_n6(other, _dir), do: other

  defp n6?(%{"scheme" => s}) when is_binary(s), do: String.starts_with?(s, "receipt_v4_")
  defp n6?(_), do: false

  defp usage(msg) do
    IO.puts(:stderr, msg)
    System.halt(2)
  end

  defp run({:ok, %{"receipts" => rs, "checkpoints" => cps, "registry" => reg} = export}, schemes) do
    n6 = [registry: reg, entry: :commercial, issuer: export["issuer"]]

    result =
      with {:ok, findings} <- walk(Enum.sort_by(rs, & &1["seq"]), reg, schemes, 0, nil, n6, []),
           :ok <- checkpoints(cps, Map.new(rs, &{&1["seq"], &1}), reg, schemes, n6),
           :ok <- coverage(rs, cps) do
        {:ok, length(rs), length(cps), findings}
      end

    case result do
      {:ok, n, c, findings} ->
        IO.puts("verified: #{n} receipts, #{c} checkpoints")
        Enum.each(findings, &IO.puts("finding: #{inspect(&1)}"))
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

  defp walk([], _reg, _schemes, _seq, _prev, _n6, findings), do: {:ok, findings}

  # A v4 row: the registry resolution here, then V4's rules, then the next row.
  defp walk([%{"scheme" => "receipt_v4_" <> _} = r | rest], reg, schemes, prev_seq, prev, n6, findings) do
    seq = r["seq"]

    with :ok <- expect(seq == prev_seq + 1, 1, {:seq_gap, prev_seq, seq}),
         {:ok, _fam, _row} <- resolve(r["scheme"], r["key_id"], reg, schemes, seq),
         {:ok, info} <- v4_row(r, prev, n6) do
      walk(rest, reg, schemes, seq, r, n6, findings ++ info.findings)
    end
  end

  defp walk([r | rest], reg, schemes, prev_seq, prev, n6, findings) do
    seq = r["seq"]

    with :ok <- expect(seq == prev_seq + 1, 1, {:seq_gap, prev_seq, seq}),
         :ok <- expect(r["prev_hash"] == (prev && prev["receipt_hash"]), 1, {:prev_hash_mismatch, seq}),
         {:ok, fam, row} <- resolve(r["scheme"], r["key_id"], reg, schemes, seq),
         bytes = pae("trinity/receipt/" <> r["scheme"], r["signed_payload"]),
         :ok <- expect(hash(bytes) == r["receipt_hash"], 1, {:hash_mismatch, seq}),
         :ok <- body_matches(r, seq),
         :ok <- signature(r, bytes, fam, row, seq) do
      walk(rest, reg, schemes, seq, r, n6, findings)
    end
  end

  defp v4_row(r, prev, n6) do
    case apply(v4(), :verify_row, [r, prev && link(prev), n6]) do
      {:error, 1, {:n6, seq, :signature_invalid}} -> {:error, 1, {:signature_invalid, seq}}
      other -> other
    end
  end

  # A row's link id, as the next v4 row names it: a v4 row's statement_id (its receipt_hash), or
  # SHA-384 over a v2 or v3 row's PAE bytes.
  defp link(%{"scheme" => "receipt_v4_" <> _, "receipt_hash" => h}), do: Base.decode16!(h, case: :lower)
  defp link(r), do: :crypto.hash(:sha384, pae("trinity/receipt/" <> r["scheme"], r["signed_payload"]))

  defp signature(r, bytes, fam, row, seq) do
    if r["kind"] in @signed_kinds do
      with {:ok, sig} <- b64(r["signature_b64"], 1, {:signature_undecodable, seq}),
           {:ok, pub} <- b64(row["public_key_b64"], 5, {:key_undecodable, r["key_id"]}) do
        check(fam, bytes, sig, pub, seq, r["key_id"], {:signature_invalid, seq})
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

  defp checkpoints(cps, by_seq, reg, schemes, n6) do
    Enum.reduce_while(cps, :ok, fn cp, :ok ->
      r = checkpoint(cp, by_seq, reg, schemes, n6)
      if r == :ok, do: {:cont, :ok}, else: {:halt, r}
    end)
  end

  defp checkpoint(%{"body_b64" => _} = cp, by_seq, reg, schemes, n6) do
    last = cp["last_seq"]

    with %{} = tail <- by_seq[last] || {:error, 1, {:checkpoint_tail_missing, last}},
         :ok <- expect(is_integer(cp["first_seq"]) and cp["first_seq"] <= last, 1, {:checkpoint_range, last}),
         {:ok, _fam, _row} <- resolve(cp["scheme"], cp["key_id"], reg, schemes, {:checkpoint, last}) do
      case apply(v4(), :verify_checkpoint, [cp, link(tail), n6]) do
        :ok -> :ok
        {:error, 1, {:checkpoint_body_mismatch, _}} -> {:error, 1, {:checkpoint_tail_mismatch, last}}
        {:error, 1, {:n6, _at, :signature_invalid}} -> {:error, 1, {:checkpoint_signature_invalid, last}}
        error -> error
      end
    end
  end

  defp checkpoint(cp, by_seq, reg, schemes, _n6) do
    last = cp["last_seq"]

    with %{} = tail <- by_seq[last] || {:error, 1, {:checkpoint_tail_missing, last}},
         :ok <- expect(tail["receipt_hash"] == cp["tail_hash"], 1, {:checkpoint_tail_mismatch, last}),
         :ok <- expect(is_integer(cp["first_seq"]) and cp["first_seq"] <= last, 1, {:checkpoint_range, last}),
         {:ok, fam, row} <- resolve(cp["scheme"], cp["key_id"], reg, schemes, {:checkpoint, last}),
         {:ok, body} <- JSON.decode(cp["signed_payload"]) |> or_error({:error, 1, {:checkpoint_body_not_json, last}}),
         :ok <- expect(body["last_seq"] == last and body["first_seq"] == cp["first_seq"] and body["tail_hash"] == cp["tail_hash"], 1, {:checkpoint_body_mismatch, last}),
         {:ok, sig} <- b64(cp["signature_b64"], 1, {:signature_undecodable, {:checkpoint, last}}),
         {:ok, pub} <- b64(row["public_key_b64"], 5, {:key_undecodable, cp["key_id"]}) do
      check(fam, pae("trinity/checkpoint/" <> cp["scheme"], cp["signed_payload"]), sig, pub, {:checkpoint, last}, cp["key_id"], {:checkpoint_signature_invalid, last})
    end
  end

  defp coverage(rs, cps) do
    covered = cps |> Enum.flat_map(fn cp -> Enum.to_list(cp["first_seq"]..cp["last_seq"]//1) end) |> MapSet.new()
    uncovered = rs |> Enum.filter(&(&1["kind"] == "query" and not MapSet.member?(covered, &1["seq"]))) |> Enum.map(& &1["seq"])
    expect(uncovered == [], 1, {:query_receipts_uncovered, uncovered})
  end

  # Slice 139. :crypto.verify raises, rather than answering, where the runtime refuses the algorithm
  # (FIPS mode refuses Ed25519; OpenSSL before 3.5, and FIPS mode on Red Hat's provider, refuse
  # ML-DSA-87) and also for a public key it cannot use, with the same badarg and error shapes. A
  # fresh key pair of the family says which: if the runtime cannot sign and verify one, it refuses
  # the algorithm; if it can, the registered key is the problem. Both are 5: no judgement.
  defp check(fam, bytes, sig, pub, at, key_id, invalid) do
    expect(verify(fam, bytes, sig, pub), 1, invalid)
  rescue
    e in ErlangError ->
      case e.original do
        {reason, _, _} when reason in [:notsup, :badarg, :error] ->
          if runs?(fam), do: {:error, 5, {:key_undecodable, key_id}}, else: {:error, 5, {:alg_unavailable, at, elem(fam, 0)}}

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  defp runs?(fam) do
    {pub, priv} = keypair(fam)
    verify(fam, "probe", sign(fam, "probe", priv), pub) == true
  rescue
    _ -> false
  end

  defp keypair({_, :eddsa, _, curve}), do: :crypto.generate_key(:eddsa, curve)
  defp keypair({_, :ecdsa, _, curve}), do: :crypto.generate_key(:ecdh, curve)
  defp keypair({_, :mldsa87, _, _}), do: :crypto.generate_key(:mldsa87, [])

  defp sign({_, :eddsa, _, curve}, bytes, priv), do: :crypto.sign(:eddsa, :none, bytes, [priv, curve])
  defp sign({_, :ecdsa, digest, curve}, bytes, priv), do: :crypto.sign(:ecdsa, digest, bytes, [priv, curve])
  defp sign({_, :mldsa87, _, _}, bytes, priv), do: :crypto.sign(:mldsa87, :none, bytes, priv)

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
