# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Property.SpaceIdentityTest do
  @moduledoc """
  Slice 133, AC1's property: changing any one of the fourteen identity fields of an embedding
  space yields a different space ID.

  This is the "is this the same thing" shape docs/03 asks a property for. The failure it guards
  is quiet: two spaces that share an ID share a store, and a store holding vectors of two spaces
  answers by comparing numbers that mean different things. Before slice 133 the identity was
  `embedding_model` alone, so a new revision of the same model, the same model truncated to
  another width or served by another runtime, all collided; the red run of this file against
  that identity is in the slice's NOTES.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.Memory.Space

  # Every leaf of the struct, with a generator of its values. The two compound identity fields
  # (`max_input`, `runtime`) have two leaves each, so sixteen leaves cover the fourteen fields.
  @string_leaves ~w(model_id revision weights_digest tokenizer_digest pooling normalisation
                    quantization query_prompt document_prompt truncation runtime runtime_version
                    locality)a
  @int_or_none_leaves ~w(max_input_tokens num_ctx)a
  @leaves [:dim | @string_leaves ++ @int_or_none_leaves]

  defp text, do: string(:printable, max_length: 24)

  defp int_or_none, do: one_of([integer(1..100_000), constant("none"), constant("unrecorded")])

  defp space do
    gen all(
          strings <- fixed_list(Enum.map(@string_leaves, fn _ -> text() end)),
          dim <- integer(1..4096),
          ints <- fixed_list(Enum.map(@int_or_none_leaves, fn _ -> int_or_none() end))
        ) do
      fields =
        Enum.zip(@string_leaves, strings) ++
          [{:dim, dim}] ++ Enum.zip(@int_or_none_leaves, ints)

      struct!(Space, fields)
    end
  end

  # A different value for one leaf, of the type that leaf holds.
  defp other(:dim, old), do: filter(integer(1..4096), &(&1 != old))
  defp other(leaf, old) when leaf in @int_or_none_leaves, do: filter(int_or_none(), &(&1 != old))
  defp other(_leaf, old), do: filter(text(), &(&1 != old))

  property "changing any one identity field changes the space ID" do
    check all(
            s <- space(),
            leaf <- member_of(@leaves),
            value <- other(leaf, Map.fetch!(s, leaf))
          ) do
      mutated = Map.put(s, leaf, value)

      refute Space.id(mutated) == Space.id(s),
             "the space ID did not change when #{leaf} went from " <>
               "#{inspect(Map.fetch!(s, leaf))} to #{inspect(value)}"
    end
  end

  test "the leaves cover the fourteen identity fields named in the moduledoc" do
    covered =
      @leaves
      |> Enum.map(fn
        l when l in [:max_input_tokens, :truncation] -> "max_input"
        l when l in [:runtime, :runtime_version] -> "runtime"
        l -> Atom.to_string(l)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert covered == Enum.sort(Space.identity_fields())
    assert length(Space.identity_fields()) == 14
    # And the struct has no field this test does not mutate.
    assert Enum.sort(Map.keys(Space.__struct__()) -- [:__struct__]) == Enum.sort(@leaves)
  end

  test "two revisions of one model are two spaces (the case today's identity merged)" do
    a = example()
    b = %{a | revision: "a-later-commit"}
    refute Space.id(a) == Space.id(b)
    assert Space.id(a) == Space.id(Space.from_manifest(Space.manifest(a)))
    assert Space.id(a) =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp example do
    %Space{
      model_id: "sentence-transformers/static-retrieval-mrl-en-v1",
      revision: "f60985c706f192d45d218078e49e5a8b6f15283a",
      weights_digest: "unrecorded",
      tokenizer_digest: "unrecorded",
      dim: 256,
      pooling: "mean",
      normalisation: "l2",
      quantization: "int8",
      query_prompt: "",
      document_prompt: "",
      max_input_tokens: "none",
      truncation: "none",
      runtime: "trinity-static",
      runtime_version: "1",
      locality: "in_process",
      num_ctx: "none"
    }
  end
end
