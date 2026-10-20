# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.CBOR do
  @moduledoc """
  The N6 subset of CBOR: an encoder that can only produce the deterministic encoding, and a
  decoder that refuses every byte string that is not exactly the deterministic encoding of a
  value in the subset (slice 138; the profile's rules E1 to E11, `Trinity.N6.Profile`).

  ## Values

    * integers in [-2^63, 2^64-1];
    * `{:bytes, binary}` for a byte string and `{:text, binary}` for a text string, which must be
      valid UTF-8 in Unicode NFC. A bare binary is refused: in signed data, bytes and text differ in
      meaning, and an untagged binary that happens to be valid UTF-8 would otherwise change type;
    * lists (arrays);
    * maps whose keys are integers in 0..2^32-1;
    * `true`, `false` and `nil`.

  The encoding is RFC 8949 section 4.2.1's core deterministic encoding: every argument in its
  shortest form, definite lengths only, map keys in the bytewise order of their encodings (for
  unsigned integer keys in shortest form, the same as numeric order).

  ## Decoding

  `decode/1` reads the input once, left to right and depth first, and stops at the first defect,
  answering its code and byte offset. Nothing from an input that fails is returned. At each head
  the checks run in this order, which is this tree's provisional answer to the profile's open
  question of precedence (its VB1):

    1. the head byte exists (`truncated`);
    2. additional information 28 to 30, or 31 where no indefinite form exists, or a lone break
       (`not_well_formed`); 31 on a byte string, text string, array or map (`indefinite_length`);
    3. a tag (`tag_forbidden`); a float (`float_forbidden`); a simple value other than false, true
       and null (`simple_forbidden`, or `not_well_formed` for `0xf8` below 32);
    4. the argument's bytes exist (`truncated`) and it is in its shortest form (`noncanonical`);
    5. the item count (`too_many_items`);
    6. a negative integer below -2^63 (`int_out_of_range`); a string's bytes exist (`truncated`);
       a text string's length, validity and form (`text_too_long`, `invalid_utf8`, `not_nfc`); a
       container's depth (`too_deep`);
    7. inside a map, for each key: its major type (`key_not_uint`), the key itself by the rules
       above, its value at most 2^32-1 (`key_not_uint`), and its encoding against the previous
       key's: equal is `duplicate_key`, lower is `noncanonical` (the profile's W2).

  The whole input is checked against the size limit first (`too_large`), and bytes after the
  top-level item are `trailing_bytes`. Last, the value is re-encoded and compared byte for byte
  with the input (E11). With the checks above complete, that comparison cannot fail; if it ever
  does, it is answered as `noncanonical`, and the suite treats it as a rule this pass missed.
  """

  import Bitwise

  alias Trinity.N6.Profile

  @typedoc "A value in the N6 subset."
  @type value ::
          integer()
          | {:bytes, binary()}
          | {:text, binary()}
          | [value()]
          | %{optional(non_neg_integer()) => value()}
          | boolean()
          | nil

  @uint64_max 0xFFFF_FFFF_FFFF_FFFF
  @int64_min -0x8000_0000_0000_0000
  @nint_arg_max 0x7FFF_FFFF_FFFF_FFFF
  @key_max 0xFFFF_FFFF

  @limits Profile.limits()
  @max_depth @limits.depth
  @max_items @limits.items
  @max_text @limits.text
  @max_size @limits.size

  ## Encoding

  @doc """
  The deterministic encoding of a value, or the code of the first part of it outside the subset.
  Limits are not applied: they bound what is decoded, not what is built.
  """
  @spec encode(value()) :: {:ok, binary()} | {:error, Profile.code()}
  def encode(value) do
    {:ok, value |> enc() |> IO.iodata_to_binary()}
  catch
    {:n6_encode, code} -> {:error, code}
  end

  @doc "As `encode/1`, raising `ArgumentError` with the code on a value outside the subset."
  @spec encode!(value()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, bytes} ->
        bytes

      {:error, code} ->
        raise ArgumentError, "not an N6 value (#{code}): #{inspect(value, limit: 8)}"
    end
  end

  defp enc(n) when is_integer(n) and n >= 0 and n <= @uint64_max, do: head(0, n)
  defp enc(n) when is_integer(n) and n < 0 and n >= @int64_min, do: head(1, -1 - n)
  defp enc(n) when is_integer(n), do: throw({:n6_encode, :int_out_of_range})
  defp enc(f) when is_float(f), do: throw({:n6_encode, :float_forbidden})
  defp enc(false), do: <<0xF4>>
  defp enc(true), do: <<0xF5>>
  defp enc(nil), do: <<0xF6>>
  defp enc({:bytes, b}) when is_binary(b), do: [head(2, byte_size(b)), b]

  defp enc({:text, s}) when is_binary(s) do
    case text_defect(s) do
      nil -> [head(3, byte_size(s)), s]
      code -> throw({:n6_encode, code})
    end
  end

  defp enc(items) when is_list(items), do: [head(4, length(items)) | Enum.map(items, &enc/1)]

  defp enc(map) when is_map(map) do
    keys = Map.keys(map)

    unless Enum.all?(keys, &(is_integer(&1) and &1 >= 0 and &1 <= @key_max)),
      do: throw({:n6_encode, :key_not_uint})

    [
      head(5, map_size(map))
      | for(k <- Enum.sort(keys), do: [head(0, k), enc(Map.fetch!(map, k))])
    ]
  end

  defp enc(_other), do: throw({:n6_encode, :value_not_n6})

  defp head(major, n) when n < 24, do: <<major <<< 5 ||| n>>
  defp head(major, n) when n <= 0xFF, do: <<major <<< 5 ||| 24, n>>
  defp head(major, n) when n <= 0xFFFF, do: <<major <<< 5 ||| 25, n::16>>
  defp head(major, n) when n <= 0xFFFF_FFFF, do: <<major <<< 5 ||| 26, n::32>>
  defp head(major, n), do: <<major <<< 5 ||| 27, n::64>>

  # Erlang's UTF-8 matching refuses overlong forms and surrogates, which is what E8 asks.
  defp text_defect(s) do
    cond do
      not String.valid?(s) -> :invalid_utf8
      :unicode.characters_to_nfc_binary(s) != s -> :not_nfc
      true -> nil
    end
  end

  ## Decoding

  @doc """
  The value a byte string is the deterministic encoding of, or the code and byte offset of its
  first defect. See the moduledoc for the order of checks.
  """
  @spec decode(binary()) :: {:ok, value()} | {:error, Profile.code(), non_neg_integer()}
  def decode(bin) when is_binary(bin) and byte_size(bin) > @max_size, do: {:error, :too_large, 0}

  def decode(bin) when is_binary(bin) do
    with {:ok, value} <- pass(bin) do
      if encode(value) == {:ok, bin}, do: {:ok, value}, else: {:error, :noncanonical, 0}
    end
  end

  # The one-pass checks without E11's round trip. Public for the suite only, which holds that
  # every refusal is found here and none is left to the round trip.
  @doc false
  @spec pass(binary()) :: {:ok, value()} | {:error, Profile.code(), non_neg_integer()}
  def pass(bin) when is_binary(bin) and byte_size(bin) > @max_size, do: {:error, :too_large, 0}

  def pass(bin) when is_binary(bin) do
    total = byte_size(bin)

    try do
      case item(bin, 0, 0) do
        {value, <<>>, _count} -> {:ok, value}
        {_value, rest, _count} -> {:error, :trailing_bytes, total - byte_size(rest)}
      end
    catch
      {:n6, code, rest} -> {:error, code, total - byte_size(rest)}
    end
  end

  # `depth` is the number of containers around this item; `count` the items read so far.
  defp item(<<>> = here, _depth, _count), do: fail(:truncated, here)

  defp item(<<ib, tail::binary>> = here, depth, count) do
    major = ib >>> 5
    ai = ib &&& 0x1F

    cond do
      ai in 28..30 -> fail(:not_well_formed, here)
      ai == 31 and major in 2..5 -> fail(:indefinite_length, here)
      ai == 31 -> fail(:not_well_formed, here)
      major == 6 -> fail(:tag_forbidden, here)
      major == 7 -> simple(ai, tail, here, count)
      true -> argument_item(major, ai, tail, here, depth, count)
    end
  end

  defp simple(20, tail, here, count), do: {false, tail, counted(count, here)}
  defp simple(21, tail, here, count), do: {true, tail, counted(count, here)}
  defp simple(22, tail, here, count), do: {nil, tail, counted(count, here)}
  defp simple(ai, _tail, here, _count) when ai in 25..27, do: fail(:float_forbidden, here)
  defp simple(24, <<>>, here, _count), do: fail(:truncated, here)
  defp simple(24, <<v, _::binary>>, here, _count) when v < 32, do: fail(:not_well_formed, here)
  defp simple(_ai, _tail, here, _count), do: fail(:simple_forbidden, here)

  defp argument_item(major, ai, tail, here, depth, count) do
    {arg, rest} = argument(ai, tail, here)
    count = counted(count, here)

    case major do
      0 -> {arg, rest, count}
      1 when arg > @nint_arg_max -> fail(:int_out_of_range, here)
      1 -> {-1 - arg, rest, count}
      2 -> string(:bytes, arg, rest, here, count)
      3 -> string(:text, arg, rest, here, count)
      4 -> array(arg, rest, here, depth + 1, count)
      5 -> map(arg, rest, here, depth + 1, count)
    end
  end

  defp counted(count, here) when count + 1 > @max_items, do: fail(:too_many_items, here)
  defp counted(count, _here), do: count + 1

  defp argument(ai, tail, _here) when ai < 24, do: {ai, tail}
  defp argument(24, <<v, rest::binary>>, here), do: shortest(v, 24, rest, here)
  defp argument(25, <<v::16, rest::binary>>, here), do: shortest(v, 0x100, rest, here)
  defp argument(26, <<v::32, rest::binary>>, here), do: shortest(v, 0x1_0000, rest, here)
  defp argument(27, <<v::64, rest::binary>>, here), do: shortest(v, 0x1_0000_0000, rest, here)
  defp argument(_ai, _tail, here), do: fail(:truncated, here)

  defp shortest(v, min, _rest, here) when v < min, do: fail(:noncanonical, here)
  defp shortest(v, _min, rest, _here), do: {v, rest}

  defp string(_kind, len, rest, here, _count) when byte_size(rest) < len,
    do: fail(:truncated, here)

  defp string(:bytes, len, rest, _here, count) do
    <<b::binary-size(^len), after_b::binary>> = rest
    {{:bytes, b}, after_b, count}
  end

  defp string(:text, len, _rest, here, _count) when len > @max_text,
    do: fail(:text_too_long, here)

  defp string(:text, len, rest, here, count) do
    <<s::binary-size(^len), after_s::binary>> = rest

    case text_defect(s) do
      nil -> {{:text, s}, after_s, count}
      code -> fail(code, here)
    end
  end

  # Every item takes at least one byte, so a count beyond what is left is refused before
  # anything is read: a forged count cannot make the decoder loop.
  defp array(_n, _rest, here, depth, _count) when depth > @max_depth, do: fail(:too_deep, here)
  defp array(n, rest, here, _depth, _count) when n > byte_size(rest), do: fail(:truncated, here)
  defp array(n, rest, _here, depth, count), do: elements(n, rest, depth, count, [])

  defp elements(0, rest, _depth, count, acc), do: {Enum.reverse(acc), rest, count}

  defp elements(n, rest, depth, count, acc) do
    {value, rest, count} = item(rest, depth, count)
    elements(n - 1, rest, depth, count, [value | acc])
  end

  defp map(_n, _rest, here, depth, _count) when depth > @max_depth, do: fail(:too_deep, here)
  defp map(n, rest, here, _depth, _count) when 2 * n > byte_size(rest), do: fail(:truncated, here)
  defp map(n, rest, _here, depth, count), do: pairs(n, rest, depth, count, nil, [])

  defp pairs(0, rest, _depth, count, _prev, acc), do: {Map.new(acc), rest, count}

  defp pairs(n, rest, depth, count, prev, acc) do
    case rest do
      <<kb, _::binary>> when kb >>> 5 != 0 -> fail(:key_not_uint, rest)
      _ -> :ok
    end

    {key, after_key, count} = item(rest, depth, count)
    if key > @key_max, do: fail(:key_not_uint, rest)
    key_bytes = binary_part(rest, 0, byte_size(rest) - byte_size(after_key))

    cond do
      prev == nil or key_bytes > prev -> :ok
      key_bytes == prev -> fail(:duplicate_key, rest)
      true -> fail(:noncanonical, rest)
    end

    {value, after_value, count} = item(after_key, depth, count)
    pairs(n - 1, after_value, depth, count, key_bytes, [{key, value} | acc])
  end

  @spec fail(Profile.code(), binary()) :: no_return()
  defp fail(code, at), do: throw({:n6, code, at})
end
