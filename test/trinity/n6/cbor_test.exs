# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.CBORTest do
  @moduledoc """
  Slice 138, AC1 to AC3: the N6 codec against Trinity's provisional vectors (`test/fixtures/n6/`),
  RFC 8949 Appendix A where the subset reaches, a property over generated values, and the limits.
  The vectors' bytes are hex literals in `scripts/n6_vectors.exs`, not output of this encoder.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trinity.N6.{CBOR, Profile, Unicode15}
  alias Trinity.TestSupport.N6Vectors

  @limits Profile.limits()

  describe "AC1: positive vectors" do
    test "every positive vector encodes to its bytes and decodes to its value" do
      vectors = N6Vectors.positive("encoding")
      assert length(vectors) > 40, "only #{length(vectors)} positive vectors found"

      for {id, bytes, value} <- vectors do
        assert CBOR.encode(value) == {:ok, bytes}, "#{id}: encoding differs"
        assert CBOR.decode(bytes) == {:ok, value}, "#{id}: decoding differs"
      end
    end

    test "the RFC 8949 Appendix A examples inside the subset are among them" do
      from_rfc =
        for path <- Path.wildcard(Path.join(N6Vectors.root(), "encoding/positive/*.desc.json")),
            path |> File.read!() |> JSON.decode!() |> Map.fetch!("source") ==
              "RFC 8949 Appendix A",
            do: path

      assert length(from_rfc) >= 30
    end

    property "every generated value round-trips" do
      check all(value <- n6_value()) do
        assert {:ok, bytes} = CBOR.encode(value)
        assert CBOR.decode(bytes) == {:ok, value}
      end
    end

    property "every byte string the decoder accepts re-encodes to itself" do
      check all(
              value <- n6_value(),
              bytes = CBOR.encode!(value),
              at <- StreamData.integer(0..(byte_size(bytes) - 1)),
              xor <- StreamData.integer(1..255)
            ) do
        <<pre::binary-size(^at), b, post::binary>> = bytes
        mutant = <<pre::binary, Bitwise.bxor(b, xor), post::binary>>

        case CBOR.decode(mutant) do
          {:ok, decoded} -> assert CBOR.encode(decoded) == {:ok, mutant}
          {:error, code, _offset} -> assert is_map_key(Profile.codes(), code)
        end
      end
    end
  end

  describe "AC2: negative vectors" do
    test "every negative vector is refused with its code" do
      vectors = N6Vectors.negative("encoding")
      assert length(vectors) > 50, "only #{length(vectors)} negative vectors found"

      # Every mismatch is collected, so a planted defect shows which classes it turned red.
      wrong =
        for {defect, id, bytes, code} <- vectors,
            answer = CBOR.decode(bytes),
            not match?({:error, ^code, _}, answer),
            do: "#{defect}/#{id}: #{inspect(answer)}, expected #{code}"

      assert wrong == [], "refused wrongly or accepted:\n" <> Enum.join(wrong, "\n")
      assert Enum.all?(vectors, fn {_, _, _, code} -> Profile.exit_of(code) == 1 end)
    end

    test "nested inside an array and a map value, each is refused with the same code" do
      for {defect, id, bytes, code} <- N6Vectors.negative("encoding") do
        assert {:error, ^code, _} = CBOR.decode(<<0x81>> <> bytes), "#{defect}/#{id} in an array"

        assert {:error, ^code, _} = CBOR.decode(<<0xA1, 0x00>> <> bytes),
               "#{defect}/#{id} as a map value"
      end
    end

    test "every refusal is found by the one pass, none is left to the round trip" do
      for {defect, id, bytes, code} <- N6Vectors.negative("encoding") do
        assert {:error, ^code, _} = CBOR.pass(bytes), "#{defect}/#{id}: only E11 refused it"
      end
    end

    test "the encoder refuses what the decoder refuses, by the same code" do
      assert CBOR.encode(1.0) == {:error, :float_forbidden}
      assert CBOR.encode(-0x8000_0000_0000_0001) == {:error, :int_out_of_range}
      assert CBOR.encode(0x1_0000_0000_0000_0000) == {:error, :int_out_of_range}
      assert CBOR.encode(%{-1 => 0}) == {:error, :key_not_uint}
      assert CBOR.encode(%{0x1_0000_0000 => 0}) == {:error, :key_not_uint}
      assert CBOR.encode(%{"a" => 0}) == {:error, :key_not_uint}
      assert CBOR.encode({:text, "é"}) == {:error, :nfc_maybe}
      assert CBOR.encode({:text, <<0xFF>>}) == {:error, :invalid_utf8}
      assert CBOR.encode("bare") == {:error, :value_not_n6}
      assert CBOR.encode(:atom) == {:error, :value_not_n6}
    end
  end

  describe "AC3: limits, at the limit and one past it" do
    test "depth" do
      assert {:ok, _} = CBOR.decode(String.duplicate(<<0x81>>, @limits.depth - 1) <> <<0x80>>)

      assert {:error, :too_deep, _} =
               CBOR.decode(String.duplicate(<<0x81>>, @limits.depth) <> <<0x80>>)
    end

    test "items, the top-level item and map keys included" do
      at = @limits.items - 1
      assert {:ok, list} = CBOR.decode(<<0x99, at::16>> <> :binary.copy(<<0>>, at))
      assert length(list) == at

      past = @limits.items

      assert {:error, :too_many_items, _} =
               CBOR.decode(<<0x9A, past::32>> <> :binary.copy(<<0>>, past))

      # A map of n pairs is 2n + 1 items.
      pairs = div(@limits.items - 1, 2)

      map =
        <<0xB9, pairs::16>> <>
          IO.iodata_to_binary(for k <- 0..(pairs - 1), do: [CBOR.encode!(k), 0])

      assert {:ok, decoded} = CBOR.decode(map)
      assert map_size(decoded) == pairs
    end

    test "text, in UTF-8 bytes" do
      at = @limits.text
      assert {:ok, {:text, _}} = CBOR.decode(<<0x7A, at::32>> <> :binary.copy("a", at))

      past = at + 1

      assert {:error, :text_too_long, 0} =
               CBOR.decode(<<0x7A, past::32>> <> :binary.copy("a", past))
    end

    test "size, the whole input" do
      at = @limits.size - 5
      assert {:ok, {:bytes, b}} = CBOR.decode(<<0x5A, at::32>> <> :binary.copy(<<0>>, at))
      assert byte_size(b) == at

      assert {:error, :too_large, 0} =
               CBOR.decode(<<0x5A, at + 1::32>> <> :binary.copy(<<0>>, at + 1))
    end

    test "a forged count larger than the input is refused before anything is read" do
      assert {:error, :truncated, 0} = CBOR.decode(<<0x9B, 0xFFFF_FFFF_FFFF_FFFF::64>>)
      assert {:error, :truncated, 0} = CBOR.decode(<<0xBB, 0xFFFF_FFFF_FFFF_FFFF::64>>)
    end
  end

  # Values in the subset. Text is printable strings kept to the code points the text rule passes
  # on their own (assigned in Unicode 15.0.0, not Cf, class 0, NFC_QC Yes), so every string is one
  # an encoder may be given. No normaliser is involved.
  defp n6_value do
    leaf =
      StreamData.one_of([
        StreamData.integer(-0x8000_0000_0000_0000..0xFFFF_FFFF_FFFF_FFFF),
        StreamData.integer(-30..30),
        StreamData.map(StreamData.binary(max_length: 40), &{:bytes, &1}),
        StreamData.map(StreamData.string(:printable, max_length: 20), &{:text, passing(&1)}),
        StreamData.member_of([true, false, nil])
      ])

    key = StreamData.one_of([StreamData.integer(0..30), StreamData.integer(0..0xFFFF_FFFF)])

    StreamData.tree(leaf, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 5),
        StreamData.map_of(key, child, max_length: 5)
      ])
    end)
    |> StreamData.filter(&(depth(&1) <= @limits.depth))
  end

  defp passing(s) do
    for <<cp::utf8 <- s>>,
        not Unicode15.unassigned?(cp),
        not Unicode15.format_control?(cp),
        Unicode15.ccc(cp) == 0,
        Unicode15.nfc_qc(cp) == :yes,
        into: "",
        do: <<cp::utf8>>
  end

  defp depth(v) when is_list(v), do: 1 + Enum.reduce(v, 0, &max(depth(&1), &2))
  defp depth(v) when is_map(v), do: 1 + Enum.reduce(Map.values(v), 0, &max(depth(&1), &2))
  defp depth(_v), do: 0
end
