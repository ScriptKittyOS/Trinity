# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.V4 do
  @moduledoc """
  Receipts v4 (slice 140): every row and checkpoint is an N6 statement, signed rows and checkpoints
  in the single-signer carrier, under the profile publisher's Decision of 2026-10-20 (17:24Z, and its
  17:27Z correction).

  ## Kinds, numbers and `typ`

  Six kinds in Trinity's provisional block 0x83, version 1: key 0 is
  `(0x83 << 24) | (kind << 8) | 1` and the `typ` is
  `application/vnd.example.b83.receipt-<kind>.v0+cose`, one `typ` per kind whatever the key's
  algorithm, which the key's registration names (`kinds/0`, `typ/1`, `schema_number/1`). All of it is
  provisional and re-issued under N21 at v1.

  ## The body

  Common keys: 1 `issuer` (required in every signed body, and written in every body), 7 `prev` (the
  predecessor's link id as a Digest; absent only at seq 1). A row, 16 to 22: `seq`, `chain_scope`,
  `at` (signed microseconds since the Unix epoch, UTC), `clock` (`{1: wall, 2: counter, 3: node}`),
  `subject` and `decision` (ForeignRefs, below), `fingerprint`. A checkpoint, 16 to 23: `first_seq`,
  `chain_scope`, `at`, `last_seq`, `tail` (the tail row's link id as a Digest), `boot` (the boot
  receipt's `receipt_hash`, as text, since the boot chain may begin before v4), `reason`.

  These are exactly the fields a reader of a receipt judged before v4 (the verifier's body-to-column
  check, the retired-key window, the merge's device), and what a checkpoint covers. Nothing else of
  `subject` or `decision` is judged by anything, so both stay opaque.

  ## `subject` and `decision`

  Each is the RFC 8785 JSON of a map Trinity builds, carried as a ForeignRef
  `{0: Digest, 1: length, 2: "application/json"}`, the bytes stored beside the row and verified as
  stored, never re-encoded. No receipt carries a tool call's arguments or its result (those enter as
  the approval fingerprint and `content_digest`); values of outside origin inside the maps are
  decoded strings whose exact received bytes are kept nowhere, so the maps are content Trinity
  originates, for which the Decision allows RFC 8785 (point 4; Trinity's correction of 2026-10-20
  17:48Z asks the publisher to confirm). Bytes missing are `foreign_bytes_missing`, a finding; bytes
  that do not match are `foreign_digest_mismatch`, invalid for the attachment and never for the
  signed statement.

  ## Linking

  A row's link id is its `statement_id`, SHA-384 over `N6enc({0: 0xFFFF0002, 1: typ, 2: body})`,
  the same whether or not the row is signed, and its `receipt_hash` column is that id in hex. The
  first v4 row after a v2 or v3 row links to SHA-384 over that row's PAE bytes, the bytes its own
  SHA-256 `receipt_hash` covers, because a Digest carries SHA-384 only (`legacy_link/1`).

  This module depends on `Trinity.N6` and nothing else, so `bin/verify_receipt.exs` loads it from
  source beside the N6 files and runs the same rules as the in-app verifier.
  """

  alias Trinity.N6.{Body, Carrier, CBOR, COSE, Digest, EC2, Profile}

  @kinds %{
    "decision" => 1,
    "effect" => 2,
    "query" => 3,
    "boot" => 4,
    "cap" => 5,
    "checkpoint" => 6
  }
  @signed ~w(decision effect boot cap checkpoint)
  @json "application/json"
  @n6_alg %{"ed25519" => -19, "p384" => -51, "mldsa87" => -50}

  @foreign_ref {:map,
                %{
                  0 => {:digest, :digest, :required},
                  1 => {:length, :uint, :required},
                  2 => {:media_type, :tstr, :required}
                }}

  @row_fields %{
    1 => {:issuer, :tstr, :required},
    7 => {:prev, :digest, :optional},
    16 => {:seq, :uint, :required},
    17 => {:chain_scope, :tstr, :required},
    18 => {:at, :int, :required},
    19 =>
      {:clock,
       {:map,
        %{
          1 => {:wall, :uint, :required},
          2 => {:counter, :uint, :required},
          3 => {:node, :tstr, :required}
        }}, :required},
    20 => {:subject, @foreign_ref, :required},
    21 => {:decision, @foreign_ref, :optional},
    22 => {:fingerprint, :tstr, :optional}
  }

  @checkpoint_fields %{
    1 => {:issuer, :tstr, :required},
    16 => {:first_seq, :uint, :required},
    17 => {:chain_scope, :tstr, :required},
    18 => {:at, :int, :required},
    20 => {:last_seq, :uint, :required},
    21 => {:tail, :digest, :required},
    22 => {:boot, :tstr, :optional},
    23 => {:reason, :tstr, :required}
  }

  @doc "The six kinds and their numbers in block 0x83."
  @spec kinds() :: %{String.t() => pos_integer()}
  def kinds, do: @kinds

  @doc "Key 0 of a kind's body."
  @spec schema_number(String.t()) :: non_neg_integer()
  def schema_number(kind),
    do: Profile.statement_schema(Profile.trinity_block(), Map.fetch!(@kinds, kind), 1)

  @doc "The one `typ` of a kind."
  @spec typ(String.t()) :: String.t()
  def typ(kind) when is_map_key(@kinds, kind),
    do: "application/vnd.example.b83.receipt-" <> kind <> ".v0+cose"

  @doc "The `typ` table every v4 verifier uses: one single-signer entry per signed kind."
  @spec typ_table() :: COSE.typ_table()
  def typ_table do
    Map.new(@signed, fn kind ->
      {typ(kind),
       %{scitt: false, carrier: :single, signers: :single, schema: schema_number(kind)}}
    end)
  end

  @doc "The body schemas, as `Trinity.N6.Body` takes them."
  @spec schemas() :: [Body.schema()]
  def schemas do
    for {kind, _} <- @kinds do
      fields = if kind == "checkpoint", do: @checkpoint_fields, else: @row_fields
      %{kind: body_kind(kind), version: schema_number(kind), fields: fields}
    end
  end

  defp body_kind(kind), do: "trinity.receipt." <> kind

  @doc "Whether a kind's statements are signed one by one (`query` rows are checkpointed)."
  @spec signed?(String.t()) :: boolean()
  def signed?(kind), do: kind in @signed

  @doc "The N6 algorithm of a registry row's algorithm name."
  @spec n6_alg(String.t()) :: COSE.alg()
  def n6_alg(name), do: Map.fetch!(@n6_alg, name)

  ## Building

  @doc """
  The body bytes of a row. `fields`: `issuer`, `seq`, `chain_scope`, `prev` (48 bytes or nil), `at`
  (microseconds), `clock` (`{wall, counter, node}`), `subject` and `decision` (their RFC 8785 bytes,
  `decision` nil when the row has none), `fingerprint` (or nil).
  """
  @spec row_body(String.t(), map()) :: {:ok, binary()} | {:error, Profile.code()}
  def row_body(kind, f) when kind != "checkpoint" do
    {wall, counter, node} = f.clock

    body =
      %{
        0 => schema_number(kind),
        1 => {:text, f.issuer},
        16 => f.seq,
        17 => {:text, f.chain_scope},
        18 => f.at,
        19 => %{1 => wall, 2 => counter, 3 => {:text, node}},
        20 => Digest.foreign_ref(f.subject, @json)
      }
      |> put_if(7, f.prev && Digest.of_value(f.prev))
      |> put_if(21, f.decision && Digest.foreign_ref(f.decision, @json))
      |> put_if(22, f.fingerprint && {:text, f.fingerprint})

    Body.encode(body, body_kind(kind), schemas())
  end

  @doc """
  The body bytes of a checkpoint. `fields`: `issuer`, `first_seq`, `last_seq`, `chain_scope`, `tail`
  (the tail row's link id, 48 bytes), `boot` (text or nil), `reason`, `at` (microseconds).
  """
  @spec checkpoint_body(map()) :: {:ok, binary()} | {:error, Profile.code()}
  def checkpoint_body(f) do
    body =
      %{
        0 => schema_number("checkpoint"),
        1 => {:text, f.issuer},
        16 => f.first_seq,
        17 => {:text, f.chain_scope},
        18 => f.at,
        20 => f.last_seq,
        21 => Digest.of_value(f.tail),
        23 => {:text, f.reason}
      }
      |> put_if(22, f.boot && {:text, f.boot})

    Body.encode(body, body_kind("checkpoint"), schemas())
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, false), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc "A body's `statement_id`: SHA-384 over `N6enc({0: 0xFFFF0002, 1: typ, 2: body})`."
  @spec statement_id(String.t(), binary()) :: binary()
  def statement_id(kind, body) when is_binary(body) do
    preimage =
      CBOR.encode!(%{
        0 => Profile.schema(:statement_id),
        1 => {:text, typ(kind)},
        2 => {:bytes, body}
      })

    :crypto.hash(:sha384, preimage)
  end

  @doc "The link id of a v2 or v3 row, as a v4 row names it: SHA-384 over its PAE bytes."
  @spec legacy_link(binary()) :: binary()
  def legacy_link(pae_bytes) when is_binary(pae_bytes), do: :crypto.hash(:sha384, pae_bytes)

  @doc """
  The protected header for a kind under a key: `kid` the key's thumbprint, `alg` its algorithm.
  """
  @spec protected(String.t(), COSE.alg(), binary()) :: binary()
  def protected(kind, alg, public),
    do: COSE.protected_header(COSE.thumbprint(alg, public), typ(kind), nil, alg)

  @doc """
  The carrier for a body, given the signature over its ToBeSigned in the form the key's algorithm
  returns from `:crypto` (DER for ESP384, converted here to `r || s`).
  """
  @spec carrier(binary(), binary(), COSE.alg(), binary()) :: {:ok, binary()} | :error
  def carrier(protected, body, alg, signature) do
    with {:ok, signature} <- n6_signature(alg, signature) do
      {:ok, Carrier.encode(%{protected: protected, payload: body, signature: signature})}
    end
  end

  defp n6_signature(-51, der), do: EC2.from_der(der)
  defp n6_signature(_alg, signature), do: {:ok, signature}

  ## Verifying

  @doc """
  Verifies one v4 row of an export, given its predecessor's link id (nil at seq 1). `opts`:
  `registry` (the export's rows), `entry` (`:commercial` or `:nss`), `issuer` (the issuer every
  row must name, when the export names one). Answers the row's link id, its signed `at`, its
  clock's node and any findings about its attachments, or `{:error, exit, reason}`.
  """
  @spec verify_row(map(), binary() | nil, keyword()) ::
          {:ok, %{link: binary(), at: integer(), node: String.t(), findings: [tuple()]}}
          | {:error, 1 | 5, term()}
  def verify_row(r, prev_link, opts) do
    seq = r["seq"]
    kind = r["kind"]

    with :ok <- expect(is_map_key(@kinds, kind) and kind != "checkpoint", 1, {:unknown_kind, seq}),
         {:ok, body} <- b64(r["body_b64"], {:body_missing, seq}),
         link = statement_id(kind, body),
         :ok <- expect(hex(link) == r["receipt_hash"], 1, {:hash_mismatch, seq}),
         {:ok, value} <- decode_body(body, kind, seq),
         :ok <- columns(value, r, prev_link, seq),
         :ok <- issuer(value, opts, seq),
         :ok <- signature(kind, r, body, opts, seq) do
      {:ok,
       %{
         link: link,
         at: value[18],
         node: text(value[19][3]),
         findings: attachments(value, r, seq)
       }}
    end
  end

  defp decode_body(body, kind, seq) do
    case Body.decode(body, body_kind(kind), schemas()) do
      {:ok, value, _schema} -> {:ok, value}
      {:error, code, _offset} -> {:error, 1, {:n6, seq, code}}
    end
  end

  # The columns a reader filters and sorts by must be what the signed body says.
  defp columns(value, r, prev_link, seq) do
    prev_ok =
      case prev_link do
        nil -> not is_map_key(value, 7) and r["prev_hash"] == nil
        link -> value[7] == Digest.of_value(link) and r["prev_hash"] == hex(link)
      end

    cond do
      not prev_ok ->
        {:error, 1, {:prev_hash_mismatch, seq}}

      value[16] != seq or text(value[17]) != r["chain_scope"] ->
        {:error, 1, {:body_column_mismatch, seq}}

      true ->
        :ok
    end
  end

  defp issuer(value, opts, seq) do
    case Keyword.get(opts, :issuer) do
      nil -> :ok
      issuer -> expect(text(value[1]) == issuer, 1, {:issuer_mismatch, seq})
    end
  end

  defp signature(kind, r, body, opts, at) do
    case {signed?(kind), r["carrier_b64"]} do
      {false, nil} -> :ok
      {false, _carrier} -> {:error, 1, {:unexpected_signature, at}}
      {true, nil} -> {:error, 1, {:signature_missing, at}}
      {true, b64} -> verify_carrier(b64, body, r["key_id"], opts, at)
    end
  end

  defp verify_carrier(b64, body, key_id, opts, at) do
    with {:ok, carrier} <- b64(b64, {:signature_undecodable, at}),
         {:ok, parts} <- n6(Carrier.decode(carrier), at),
         :ok <- expect(parts.payload == body, 1, {:carrier_payload_mismatch, at}),
         {:ok, row} <- registry_row(opts, key_id, at) do
      case Carrier.verify(carrier, keys: keys(row), typ: typ_table(), entry: entry(opts)) do
        {:ok, _} -> :ok
        {:error, 5, :alg_unavailable} -> {:error, 5, {:alg_unavailable, at, row["algorithm"]}}
        {:error, exit, code} -> {:error, exit, {:n6, at, code}}
      end
    end
  end

  defp n6({:ok, parts}, _at), do: {:ok, parts}
  defp n6({:error, code}, at), do: {:error, 1, {:n6, at, code}}

  defp registry_row(opts, key_id, at) do
    case opts
         |> Keyword.get(:registry, [])
         |> Enum.filter(&(&1["key_id"] == key_id))
         |> List.last() do
      nil -> {:error, 5, {:unknown_key_id, at, key_id}}
      row -> {:ok, row}
    end
  end

  # The registry row is the one the row's `key_id` column names; its `kid` is recomputed from the
  # row's public key under the row's algorithm, so a header naming another key is unknown here.
  defp keys(row) do
    with {:ok, pub} <- b64(row["public_key_b64"], :no_public),
         {:ok, alg} <- Map.fetch(@n6_alg, row["algorithm"]) do
      key_for(thumbprint(alg, pub), %{alg: alg, public: pub})
    else
      _ -> fn _ -> :error end
    end
  end

  defp key_for(kid, key), do: fn k -> if k == kid, do: {:ok, key}, else: :error end

  defp thumbprint(alg, pub) do
    COSE.thumbprint(alg, pub)
  rescue
    FunctionClauseError -> nil
  end

  defp entry(opts), do: Keyword.get(opts, :entry, :commercial)

  @doc "The findings about a row's attachments: none, or which bytes are missing or wrong."
  @spec attachments(map(), map(), term()) :: [tuple()]
  def attachments(value, r, seq) do
    for {key, field, column} <- [{20, :subject, "subject_b64"}, {21, :decision, "decision_b64"}],
        ref = value[key],
        ref != nil,
        finding = attachment(ref, r[column], field, seq),
        finding != nil,
        do: finding
  end

  defp attachment(_ref, nil, field, seq), do: {:foreign_bytes_missing, seq, field}

  defp attachment(%{0 => digest, 1 => length}, b64, field, seq) do
    case Base.decode64(b64) do
      {:ok, bytes} when byte_size(bytes) == length ->
        if Digest.matches?(digest, bytes), do: nil, else: {:foreign_digest_mismatch, seq, field}

      _ ->
        {:foreign_digest_mismatch, seq, field}
    end
  end

  @doc """
  Verifies one v4 checkpoint, given the link id of the row at its `last_seq`. `opts` as
  `verify_row/3`.
  """
  @spec verify_checkpoint(map(), binary(), keyword()) :: :ok | {:error, 1 | 5, term()}
  def verify_checkpoint(cp, tail_link, opts) do
    last = cp["last_seq"]
    at = {:checkpoint, last}

    with {:ok, body} <- b64(cp["body_b64"], {:checkpoint_body_missing, last}),
         {:ok, value} <- decode_body(body, "checkpoint", at),
         :ok <-
           expect(
             value[20] == last and value[16] == cp["first_seq"] and
               text(value[17]) == cp["chain_scope"] and value[21] == Digest.of_value(tail_link) and
               cp["tail_hash"] == hex(tail_link),
             1,
             {:checkpoint_body_mismatch, last}
           ),
         :ok <- issuer(value, opts, at) do
      signature("checkpoint", cp, body, opts, at)
    end
  end

  @doc "Reads a v4 body's signed `at` and clock node, for readers that only display them."
  @spec read(String.t(), binary()) :: {:ok, map()} | :error
  def read(kind, body) do
    case Body.decode(body, body_kind(kind), schemas()) do
      {:ok, value, _} -> {:ok, value}
      _ -> :error
    end
  end

  ## Helpers

  defp b64(nil, reason), do: {:error, 1, reason}

  defp b64(s, reason) when is_binary(s) do
    case Base.decode64(s) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, 1, reason}
    end
  end

  defp text({:text, t}), do: t
  defp text(_), do: nil

  @doc "Lowercase hex."
  @spec hex(binary()) :: String.t()
  def hex(bin), do: Base.encode16(bin, case: :lower)

  defp expect(true, _code, _reason), do: :ok
  defp expect(false, code, reason), do: {:error, code, reason}
end
