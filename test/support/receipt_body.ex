# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSupport.ReceiptBody do
  @moduledoc """
  What a receipt says, for tests that read a field of it: the body as a map with string keys, the
  shape a v2 or v3 row's RFC 8785 `signed_payload` decodes to (slice 140).

  A v2 or v3 row is that decode. A v4 row's fields come from its N6 body (`seq`, `chain_scope`,
  `at`, `clock`, `fingerprint`), its columns (`scheme`, `kind`, `key_id`, `prev_hash`) and the stored
  bytes its two ForeignRefs name (`subject`, `decision`), decoded for reading. A test that judges
  what is signed reads the body itself; this is for reading what a row says.
  """

  alias Trinity.Receipts.{Receipt, Signer, V4}

  @doc "The body of a `Receipt` row, or of an exported row, as a string-keyed map."
  @spec of(Receipt.t() | map()) :: map()
  def of(%Receipt{} = r), do: r |> Receipt.to_export() |> of()

  def of(%{"scheme" => scheme} = r) do
    if Signer.n6?(scheme), do: v4(r), else: JSON.decode!(r["signed_payload"])
  end

  defp v4(r) do
    {:ok, value} = V4.read(r["kind"], Base.decode64!(r["body_b64"]))
    %{1 => wall, 2 => counter, 3 => {:text, node}} = value[19]

    %{
      "scheme" => r["scheme"],
      "seq" => value[16],
      "chain_scope" => text(value[17]),
      "prev_hash" => r["prev_hash"],
      "kind" => r["kind"],
      "key_id" => r["key_id"],
      "at" => value[18] |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
      "clock" => %{"wall" => wall, "counter" => counter, "node" => node},
      "subject" => attachment(r["subject_b64"]),
      "decision" => attachment(r["decision_b64"]),
      "fingerprint" => text(value[22])
    }
  end

  defp attachment(nil), do: nil
  defp attachment(b64), do: b64 |> Base.decode64!() |> JSON.decode!()

  defp text({:text, t}), do: t
  defp text(nil), do: nil
end
