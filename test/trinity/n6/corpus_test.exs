# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.CorpusTest do
  @moduledoc """
  Slice 138, AC10, opt-in (`mix test --only n6_corpus`): a corpus of generated bodies round-trips
  byte for byte, and every mutant the operators below make of them is refused with the operator's
  code.

  `TRINITY_N6_CORPUS` sets the number of bodies (default 1,000,000); the random source is seeded,
  so a run can be repeated. The claim is about this operator population, not about every possible
  input: a defect class no operator makes is not covered, and a new class becomes a new operator.
  """

  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2]

  alias Trinity.N6.CBOR

  @moduletag :n6_corpus
  @moduletag timeout: :infinity

  # name => the code its mutants must be refused with
  @operators %{
    nonminimal_head: :noncanonical,
    indefinite_length: :indefinite_length,
    float_value: :float_forbidden,
    tag_value: :tag_forbidden,
    simple_value: :simple_forbidden,
    text_key: :key_not_uint,
    negative_key: :key_not_uint,
    key_over_u32: :key_not_uint,
    swap_keys: :noncanonical,
    duplicate_key: :duplicate_key,
    trailing_bytes: :trailing_bytes,
    truncated: :truncated,
    not_nfc: :not_nfc
  }

  test "generated bodies round-trip and every mutant is refused with its operator's code" do
    n = String.to_integer(System.get_env("TRINITY_N6_CORPUS", "1000000"))
    :rand.seed(:exsss, {138, 10, 1})

    counts =
      Enum.reduce(1..n, %{bodies: 0}, fn i, counts ->
        body = body(i)
        bytes = CBOR.encode!(body)
        assert CBOR.decode(bytes) == {:ok, body}

        pairs = for k <- Enum.sort(Map.keys(body)), do: {CBOR.encode!(k), CBOR.encode!(body[k])}

        Enum.reduce(@operators, Map.update!(counts, :bodies, &(&1 + 1)), fn {name, code},
                                                                            counts ->
          case mutate(name, pairs, bytes) do
            nil ->
              counts

            mutant ->
              case CBOR.decode(mutant) do
                {:error, ^code, _} ->
                  Map.update(counts, name, 1, &(&1 + 1))

                other ->
                  flunk("#{name} on #{Base.encode16(bytes)}: #{inspect(other)}, expected #{code}")
              end
          end
        end)
      end)

    mutants = counts |> Map.delete(:bodies) |> Map.values() |> Enum.sum()

    IO.puts(
      "n6 corpus: #{counts.bodies} bodies round-tripped; #{mutants} of #{mutants} mutants refused"
    )

    for {name, count} <- counts |> Map.delete(:bodies) |> Enum.sort(),
        do: IO.puts("  #{name}: #{count}")

    assert map_size(counts) == map_size(@operators) + 1, "an operator made no mutant"
  end

  # A body: key 0 the version, then one to six fields of mixed types under 16..1030.
  defp body(i) do
    fields =
      for k <- Enum.take_random(16..1030, :rand.uniform(6)), into: %{}, do: {k, value(k + i)}

    Map.put(fields, 0, rem(i, 7) + 1)
  end

  defp value(x) do
    case rem(x, 6) do
      0 -> :rand.uniform(1 <<< 40) - (1 <<< 39)
      1 -> {:bytes, :rand.bytes(:rand.uniform(40) - 1)}
      2 -> {:text, Enum.random(["", "a", "café", "水", "op-#{x}"])}
      3 -> Enum.map(1..:rand.uniform(4), fn _ -> :rand.uniform(1000) end)
      4 -> Enum.random([true, false, nil])
      5 -> %{1 => :rand.uniform(100), 2 => {:text, "n"}}
    end
  end

  # Every body has fewer than 23 pairs, so its map head is one byte, 0xa0 + n.
  defp mutate(:nonminimal_head, pairs, _bytes), do: <<0xB8, length(pairs)>> <> join(pairs)
  defp mutate(:indefinite_length, pairs, _bytes), do: <<0xBF>> <> join(pairs) <> <<0xFF>>

  defp mutate(:float_value, [{k0, _v0} | rest], _bytes),
    do: map([{k0, <<0xF9, 0x3C, 0x00>>} | rest])

  defp mutate(:tag_value, [{k0, _v0} | rest], _bytes), do: map([{k0, <<0xC1, 0x00>>} | rest])

  defp mutate(:simple_value, pairs, _bytes),
    do: map(List.update_at(pairs, -1, fn {k, _} -> {k, <<0xF7>>} end))

  defp mutate(:text_key, pairs, _bytes), do: map([{<<0x61, 0x61>>, <<0x00>>} | pairs])
  defp mutate(:negative_key, pairs, _bytes), do: map(pairs ++ [{<<0x20>>, <<0x00>>}])

  defp mutate(:key_over_u32, pairs, _bytes),
    do: map(pairs ++ [{<<0x1B, 0x1_0000_0000::64>>, <<0x00>>}])

  defp mutate(:swap_keys, [a, b | rest], _bytes), do: map([b, a | rest])
  defp mutate(:swap_keys, _pairs, _bytes), do: nil
  defp mutate(:duplicate_key, [a | rest], _bytes), do: map([a, a | rest])
  defp mutate(:trailing_bytes, _pairs, bytes), do: bytes <> <<0x00>>
  defp mutate(:truncated, _pairs, bytes), do: binary_part(bytes, 0, byte_size(bytes) - 1)

  defp mutate(:not_nfc, pairs, _bytes),
    do: map(pairs ++ [{<<0x1A, 0xFFFF_FFFE::32>>, <<0x63, 0x65, 0xCC, 0x81>>}])

  defp map(pairs), do: <<0xA0 + length(pairs)>> <> join(pairs)
  defp join(pairs), do: IO.iodata_to_binary(for {k, v} <- pairs, do: [k, v])
end
