# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Property.CanonicalisationTest do
  @moduledoc """
  Slice 004 AC2: the two canonicalisers, against generated input rather than chosen input.

  These are the right first target for property testing in this tree, and the reason is what they
  are *for*. `Fingerprint` decides whether an approval still matches the call being made;
  `DefinitionDigest` decides whether a server's tool is the one the owner approved. Both answer a
  question of the form "is this the same thing", and both are wrong in the same two ways: saying
  different about two spellings of one value, or saying same about two different values.

  An example test picks the spellings someone thought of. That is exactly the set an attacker will
  not use.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Permissions.Fingerprint
  alias Trinity.Tools.DefinitionDigest

  # JSON-shaped values: what actually crosses these boundaries, since arguments arrive decoded from
  # JSON and a schema is a JSON document. Generating arbitrary terms would test a case that cannot
  # reach the code.
  defp json_scalar do
    one_of([
      string(:printable, max_length: 20),
      integer(),
      float(),
      boolean(),
      constant(nil)
    ])
  end

  defp json_value(depth \\ 2)
  defp json_value(0), do: json_scalar()

  defp json_value(depth) do
    one_of([
      json_scalar(),
      list_of(json_value(depth - 1), max_length: 3),
      map_of(string(:alphanumeric, min_length: 1, max_length: 8), json_value(depth - 1),
        max_length: 3
      )
    ])
  end

  defp json_object do
    map_of(string(:alphanumeric, min_length: 1, max_length: 8), json_value(), max_length: 5)
  end

  describe "Fingerprint" do
    property "one call has one fingerprint, whatever order its keys arrived in" do
      check all(
              args <- json_object(),
              tool <- string(:alphanumeric, min_length: 1, max_length: 12),
              scope <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        shuffled = args |> Enum.shuffle() |> Map.new()

        assert Fingerprint.of(tool, args, scope, nil) ==
                 Fingerprint.of(tool, shuffled, scope, nil),
               "two orderings of one argument map produced two fingerprints, so an approval " <>
                 "would stop matching a call that had not changed"
      end
    end

    property "changing any one of tool, args, scope or cwd changes the fingerprint" do
      check all(
              args <- json_object(),
              tool <- string(:alphanumeric, min_length: 1, max_length: 12),
              other_tool <- string(:alphanumeric, min_length: 1, max_length: 12),
              scope <- string(:alphanumeric, min_length: 1, max_length: 10),
              other_scope <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        base = Fingerprint.of(tool, args, scope, nil)

        if tool != other_tool do
          refute base == Fingerprint.of(other_tool, args, scope, nil)
        end

        if scope != other_scope do
          refute base == Fingerprint.of(tool, args, other_scope, nil),
                 "the scope is what stops one session's grant being spent in another"
        end

        refute base == Fingerprint.of(tool, args, scope, "/elsewhere")
      end
    end

    property "an added or removed argument changes the fingerprint" do
      # The key is *constructed* to be absent rather than filtered for absence. The first version
      # filtered on `not Map.has_key?(args, key)` and passed at the gate's 100 runs, then failed at
      # 3,000 with FilterTooNarrowError: as the generation size grows, generated keys collide often
      # enough that the filter rejects most candidates. `json_object/0` generates alphanumeric keys
      # only, so a key containing a hyphen cannot collide and no filter is needed. Running the
      # property wider than the gate does is what found this, which is the reason AC5 asks for it.
      check all(
              args <- json_object(),
              key <- string(:alphanumeric, min_length: 1, max_length: 8),
              value <- json_value()
            ) do
        added = key <> "-added"

        refute Fingerprint.of("t", args, "s", nil) ==
                 Fingerprint.of("t", Map.put(args, added, value), "s", nil),
               "adding an argument left the fingerprint alone, which is the approve-then-append " <>
                 "shape of the attack this binding exists to stop"
      end
    end
  end

  describe "DefinitionDigest" do
    property "one definition has one digest, whatever order its keys arrived in" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 12),
              description <- string(:printable, max_length: 40),
              schema <- json_object()
            ) do
        listed = %{"name" => name, "description" => description, "inputSchema" => schema}
        shuffled = listed |> Enum.shuffle() |> Map.new()
        assert DefinitionDigest.of(listed) == DefinitionDigest.of(shuffled)
      end
    end

    property "changing the description alone changes the digest" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 12),
              a <- string(:printable, max_length: 40),
              b <- string(:printable, max_length: 40),
              a != b
            ) do
        schema = %{"type" => "object"}

        refute DefinitionDigest.of(%{"name" => name, "description" => a, "inputSchema" => schema}) ==
                 DefinitionDigest.of(%{
                   "name" => name,
                   "description" => b,
                   "inputSchema" => schema
                 }),
               "the description is what the model reads when deciding whether to call a tool"
      end
    end

    property "changes/2 is empty exactly when the digests agree" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 12),
              d1 <- string(:printable, max_length: 30),
              d2 <- string(:printable, max_length: 30)
            ) do
        a = %{"name" => name, "description" => d1, "inputSchema" => %{"type" => "object"}}
        b = %{"name" => name, "description" => d2, "inputSchema" => %{"type" => "object"}}

        agree? = DefinitionDigest.of(a) == DefinitionDigest.of(b)

        empty? =
          DefinitionDigest.changes(
            DefinitionDigest.canonical_form(a),
            DefinitionDigest.canonical_form(b)
          ) == []

        assert agree? == empty?,
               "the digest and the field diff disagreed about whether anything changed, so a " <>
                 "drift notice could say a tool changed and name no field, or the reverse"
      end
    end
  end
end
