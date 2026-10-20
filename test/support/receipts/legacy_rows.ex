# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestReceipts.LegacyRows do
  @moduledoc """
  A chain that began before slice 140 (slice 140, AC5 to AC7): v3 rows written into `receipts`
  exactly as the writer wrote them until then (an RFC 8785 body over DSSE's PAE, SHA-256 links,
  signed through the key in custody), so a test can show the writer continuing such a chain in v4
  and every verifier reading the result. The rows go in through `BypassInserter`, the census's
  planted second path, because the writer no longer writes v3.
  """

  alias Trinity.Receipts.{Envelope, KeyCustody, Receipt}
  alias Trinity.TestReceipts.BypassInserter

  @doc """
  Plants `kinds` (a list of `"decision"` and `"query"`) as v3 rows at seq 1 to n of `scope`, under
  the selected key's family. Returns the rows.
  """
  def plant(scope, kinds) do
    %{algorithm: alg, key_id: key_id} = KeyCustody.selected()
    scheme = "receipt_v3_#{alg}"

    {rows, _prev} =
      kinds
      |> Enum.with_index(1)
      |> Enum.map_reduce(nil, fn {kind, seq}, prev ->
        body = %{
          "scheme" => scheme,
          "seq" => seq,
          "chain_scope" => scope,
          "prev_hash" => prev,
          "kind" => kind,
          "subject" => %{"legacy" => seq},
          "decision" => if(kind == "query", do: %{"ok" => true}, else: %{"outcome" => "allow"}),
          "fingerprint" => nil,
          "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "key_id" => key_id,
          "clock" => %{"wall" => 1_000 + seq, "counter" => 0, "node" => "legacy-node"}
        }

        payload = Envelope.canonical(body)
        bytes = Envelope.pae(Envelope.receipt_type(scheme), payload)
        hash = Envelope.hash(bytes)

        signature =
          if Receipt.signed?(kind) do
            {:ok, sig} = KeyCustody.sign(bytes)
            sig
          end

        {:ok, row} =
          BypassInserter.insert(%Receipt{
            chain_scope: scope,
            seq: seq,
            prev_hash: prev,
            receipt_hash: hash,
            scheme: scheme,
            kind: kind,
            signed_payload: payload,
            signature: signature,
            key_id: key_id,
            subject: body["subject"],
            subject_ref: "legacy:#{scope}:#{seq}",
            meta: %{},
            inserted_at: DateTime.utc_now()
          })

        {row, hash}
      end)

    rows
  end
end
