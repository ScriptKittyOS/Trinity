# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.SchemeMappingTest do
  @moduledoc """
  Slice 124 amendment 1, ACs 2 and 3: the receipt bytes did not change, and `docs/receipt-scheme-mapping.md`
  cannot drift from the payload it describes.

  A document that maps a field set to a standard is worth exactly as much as its agreement with the
  code, and that agreement decays silently: the next slice to add a signed field leaves the document
  describing a payload that no longer exists, and nothing anywhere fails. So the document's own
  mapping table is the population here, checked against the payload in both directions.

  Slice 140: new rows are v4, N6 statements with integer keys (`Trinity.Receipts.V4`). The v3 table
  is now checked against a v3 row as the writer signed it before slice 140 (slice 139's fixture), and
  the document's v4 table against the v4 schema, both ways.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Receipts.{Receipt, V4}

  @doc_path Path.expand("../../../docs/receipt-scheme-mapping.md", __DIR__)
  @external_resource @doc_path

  # Slice 024's field set, written out because "these fields did not change" is the criterion: a list
  # derived from the code would agree with the code by construction and could prove nothing.
  @slice_024_keys ~w(scheme seq chain_scope prev_hash kind subject decision fingerprint at key_id)

  # Slice 026 added exactly one field, under a new scheme version. Written out for the same reason,
  # and as the whole of the difference: a future slice that adds a field silently fails here.
  @slice_026_added ~w(clock)
  @current_keys @slice_024_keys ++ @slice_026_added

  # A v3 row as the writer signed it: slice 139's checked-in Ed25519 chain, its first signed row.
  defp payload_keys do
    %{"receipts" => rows} =
      "test/fixtures/receipts/ed25519_signed.json" |> File.read!() |> JSON.decode!()

    row =
      Enum.find(
        rows,
        &(&1["kind"] == "decision" and String.starts_with?(&1["scheme"], "receipt_v3_"))
      )

    row["signed_payload"] |> JSON.decode!() |> Map.keys() |> Enum.sort()
  end

  # The v4 table: rows that start with a key number, then the field's name in backticks.
  defp documented_v4 do
    Regex.scan(~r/^\| (\d+) \| `(\w+)` \|/m, doc())
    |> Enum.map(fn [_, key, name] -> {String.to_integer(key), name} end)
    |> Enum.sort()
  end

  test "slice 140: the v4 table names exactly the v4 row body's keys, with their names" do
    [schema | _] = Enum.filter(V4.schemas(), &(&1.kind == "trinity.receipt.decision"))

    fields =
      [
        {0, "schema"}
        | Enum.map(schema.fields, fn {k, {name, _, _}} -> {k, Atom.to_string(name)} end)
      ]
      |> Enum.sort()

    assert documented_v4() == fields, """
    the document's v4 table and Trinity.Receipts.V4's row body disagree.

    In the body, missing a row in the table: #{inspect(fields -- documented_v4())}
    In the table, absent from the body:      #{inspect(documented_v4() -- fields)}
    """
  end

  defp doc, do: File.read!(@doc_path)

  # The first column of every row of the mapping table, minus the header and the *(absent)* row,
  # unwrapped from its backticks and split on ", " so a cell naming two fields yields both.
  defp documented_fields do
    doc()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `"))
    |> Enum.map(fn row -> row |> String.split("|") |> Enum.at(1) |> String.trim() end)
    |> Enum.flat_map(&String.split(&1, ", "))
    |> Enum.map(&String.trim(&1, "`"))
    |> Enum.sort()
  end

  test "AC2: the signed payload's keys are slice 024's ten plus exactly what slice 026 added" do
    assert payload_keys() == Enum.sort(@current_keys)
  end

  test "AC2: slice 026 added one field and removed none, so no v2 byte could have changed" do
    assert @slice_024_keys -- @current_keys == [],
           "a field slice 024 signed is no longer in the payload. A scheme bump adds; it does " <>
             "not drop, because a dropped field changes what an old row means when it is read " <>
             "back by code that expects it."

    assert @current_keys -- @slice_024_keys == @slice_026_added
  end

  test "AC3: every signed field has a row in the mapping table, and every row names a signed field" do
    documented = documented_fields()

    assert documented != [], """
    no rows were parsed out of the mapping table in #{@doc_path}. The table's rows are expected to \
    start with "| `", so either the document was reformatted or this parser is now vacuous. A check \
    that silently matches nothing is worse than no check.
    """

    keys = payload_keys()

    assert Enum.sort(documented) == keys, """
    #{@doc_path} and the signed payload disagree.

    In the payload, missing a row in the table: #{inspect(keys -- documented)}
    In the table, absent from the payload:      #{inspect(documented -- keys)}

    A field in the payload with no row is an unmapped field in a document whose purpose is the \
    mapping. A row naming a field the payload does not carry is a claim about bytes that do not \
    exist. `subject_ref` and `meta` are row columns rather than signed fields and belong in neither.
    """
  end

  test "AC3: the kinds the document names are exactly Receipt.kinds/0" do
    assert [kind_row] = Regex.run(~r/^\| `kind` \|.*$/m, doc()),
           "the document has no `kind` row; this check has gone vacuous"

    named =
      Regex.scan(~r/`([a-z]+)`/, kind_row)
      |> Enum.map(fn [_, k] -> k end)
      |> Enum.reject(&(&1 == "kind"))
      |> Enum.sort()

    assert named == Enum.sort(Receipt.kinds()), """
    the document's `kind` row names #{inspect(named)}, Receipt.kinds/0 is \
    #{inspect(Enum.sort(Receipt.kinds()))}.
    """
  end

  test "AC3: the count the document states in prose matches the payload" do
    words = %{
      "eight" => 8,
      "nine" => 9,
      "ten" => 10,
      "eleven" => 11,
      "twelve" => 12,
      "thirteen" => 13
    }

    assert [_, word] = Regex.run(~r/exactly these (\w+) keys/, doc()),
           "the document no longer states the field count in prose; this check has gone vacuous"

    assert Map.get(words, word) == length(payload_keys()),
           "the document says #{word} keys, the payload has #{length(payload_keys())}"
  end

  test "AC4: the standards register carries an RFC 9943 row that claims no conformance" do
    register = Path.expand("../../../docs/09-standards-register.md", __DIR__) |> File.read!()

    assert [row] = Regex.run(~r/^\|.*RFC 9943.*$/m, register),
           "docs/09-standards-register.md carries no RFC 9943 row"

    assert row =~ "receipt-scheme-mapping.md", "the row names no evidence path in the tree"
    assert row =~ "not claimed", "the row does not say conformance is not claimed"
  end
end
