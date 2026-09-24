# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Property.ReceiptChainTest do
  @moduledoc """
  Slice 004 AC4: for any generated sequence of appends, the chain links.

  The existing chain tests append a chosen sequence: five decisions then three queries. The linking
  property has to hold for any sequence, because the real one is whatever the agent happened to do,
  and the mix of signed and unsigned kinds is the part most likely to have an edge: `query` rows are
  not signed, and a chain that skips a link over an unsigned row would still look right in a test
  that never puts one in the middle.
  """
  use Trinity.DataCase, async: false
  use ExUnitProperties

  alias Trinity.Receipts
  alias Trinity.Receipts.Receipt

  setup do
    scope = "prop:" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, scope: scope}
  end

  defp entry("decision", n),
    do: %{
      kind: "decision",
      subject: %{"n" => n},
      decision: %{"outcome" => "allow", "basis" => "property"},
      fingerprint: String.duplicate("a", 8) <> Integer.to_string(n)
    }

  defp entry("query", n), do: %{kind: "query", subject: %{"n" => n}}

  defp entry("effect", n),
    do: %{kind: "effect", subject: %{"n" => n}, decision: %{"outcome" => "allow"}}

  property "any sequence of kinds produces a gapless chain whose links hold", %{scope: scope} do
    check all(
            kinds <- list_of(member_of(~w(decision query effect)), min_length: 1, max_length: 12),
            max_runs: 15
          ) do
      inner = scope <> ":" <> Integer.to_string(System.unique_integer([:positive]))

      for {kind, n} <- Enum.with_index(kinds, 1) do
        assert {:ok, %Receipt{}} = Receipts.append(inner, entry(kind, n))
      end

      rows = Receipts.list(inner) |> Enum.sort_by(& &1.seq)

      assert length(rows) == length(kinds)
      assert Enum.map(rows, & &1.seq) == Enum.to_list(1..length(kinds))

      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, current] ->
        assert current.prev_hash == previous.receipt_hash,
               "seq #{current.seq} (#{current.kind}) does not link to seq #{previous.seq} " <>
                 "(#{previous.kind}). An unsigned row in the middle must still carry the link"
      end)

      assert hd(rows).prev_hash in [nil, ""]
      Receipts.stop_writer(inner)
    end
  end
end
