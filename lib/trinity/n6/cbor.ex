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
      valid UTF-8 and pass the text rule (`Trinity.N6.Unicode15`). A bare binary is refused: in
      signed data, bytes and text differ in meaning, and an untagged binary that happens to be valid
      UTF-8 would otherwise change type;
  * lists (arrays);
    * maps whose keys are integers in 0..2^32-1;
    * `true`, `false` and `nil`.

  The encoding is RFC 8949 section 4.2.1's core deterministic encoding: every argument in its
  shortest form, definite lengths only, map keys in the bytewise order of their encodings (for
  unsigned integer keys in shortest form, the same as numeric order).

  ## Decoding

  `decode/1` reads the input once, left to right and depth first, and stops at the first defect,
  answering its code and byte offset. Nothing from an input that fails is returned. The checks are
  the profile's steps D0 to D18 (N6 draft v0.1-r7 section 2.2), which fix both what is checked and
  in which order. D0 runs once; at every head, in order:

    * D1: a byte is left for the head (`truncated`);
    * D2: additional information 28 to 30, or 31 on major type 0, 1, 6 or 7 (`not_well_formed`);
    * D3: 31 on a byte string, text string, array or map (`indefinite_length`);
    * D4: the argument's bytes are all present (`truncated`), floats and simple values included;
    * D5: `0xf8` with an argument below 32 (`not_well_formed`);
    * D6: in key position, a major type other than 0 (`key_not_uint`), before any D7 check;
    * D7: a tag (`tag_forbidden`), a float (`float_forbidden`), a simple value other than false,
      true and null (`simple_forbidden`);
    * D8: the argument in its shortest form (`noncanonical`);
    * D9 and D10: a key above 2^32-1 (`key_not_uint`), then the key's encoding against the previous
      key's: equal is `duplicate_key`, lower is `noncanonical`;
    * D11: a negative integer below -2^63 (`int_out_of_range`);
    * D12: an array or map: its depth (`too_deep`), then the fit check, its count against the bytes
      from after the head to the end of the input, one per element or two per pair (`truncated`),
      then the item count raised by its declared contents (`too_many_items`);
    * D13 to D16: a string: the fit check (`truncated`), a text string's length (`text_too_long`),
      UTF-8 over the whole string (`invalid_utf8`), then the text rule at its first failing code
      point (`text_unassigned`, `text_format_control`, `not_nfc`, `nfc_maybe`).

  Bytes after the top-level item are `trailing_bytes` (D17). Last, the value is re-encoded and
  compared byte for byte with the input (E11, D18). With the checks above complete, that comparison
  cannot fail; if it ever does, it is answered as `noncanonical`, and the suite treats it as a rule
  this pass missed.
  """

  import Bitwise

  alias Trinity.N6.Profile
  alias Trinity.N6.Unicode15

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

  # D15 over the whole string, then D16. Erlang's UTF-8 matching refuses overlong forms and
  # surrogates, which is what E8 asks.
  defp text_defect(s), do: if(String.valid?(s), do: text_rule(s, 0), else: :invalid_utf8)

  # The text rule (r7 section 2.4): left to right, `last` the previous code point's combining
  # class; the first code point that fails gives the code. No normaliser is called.
  defp text_rule(<<>>, _last), do: nil
  # ASCII is assigned, not Cf, class 0 and NFC_QC Yes, so it only resets `last`.
  defp text_rule(<<cp, rest::binary>>, _last) when cp < 0x80, do: text_rule(rest, 0)

  defp text_rule(<<cp::utf8, rest::binary>>, last) do
    ccc = Unicode15.ccc(cp)

    cond do
      Unicode15.unassigned?(cp) -> :text_unassigned
      Unicode15.format_control?(cp) -> :text_format_control
      ccc != 0 and ccc < last -> :not_nfc
      true -> quick_check(Unicode15.nfc_qc(cp), rest, ccc)
    end
  end

  defp quick_check(:yes, rest, ccc), do: text_rule(rest, ccc)
  defp quick_check(:no, _rest, _ccc), do: :not_nfc
  defp quick_check(:maybe, _rest, _ccc), do: :nfc_maybe

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
      # The top-level item counts itself; every container adds its declared contents (D12).
      case item(bin, 0, 1, :value) do
        {value, <<>>, _count} -> {:ok, value}
        {_value, rest, _count} -> {:error, :trailing_bytes, total - byte_size(rest)}
      end
    catch
      {:n6, code, rest} -> {:error, code, total - byte_size(rest)}
    end
  end

  # `depth` is the number of containers around this item, `count` the items declared so far, and
  # `position` whether the item is a map key. Each clause below is one step, in the profile's order.
  defp item(<<>> = here, _depth, _count, _position), do: fail(:truncated, here)

  defp item(<<ib, tail::binary>> = here, depth, count, position) do
    major = ib >>> 5
    ai = ib &&& 0x1F

    cond do
      ai in 28..30 -> fail(:not_well_formed, here)
      ai == 31 and major in [0, 1, 6, 7] -> fail(:not_well_formed, here)
      ai == 31 -> fail(:indefinite_length, here)
      true -> head_item(major, ai, argument(ai, tail, here), here, depth, count, position)
    end
  end

  defp head_item(7, 24, {v, _rest}, here, _depth, _count, _position) when v < 32,
    do: fail(:not_well_formed, here)

  defp head_item(major, _ai, _arg, here, _depth, _count, :key) when major != 0,
    do: fail(:key_not_uint, here)

  defp head_item(6, _ai, _arg, here, _depth, _count, _position), do: fail(:tag_forbidden, here)
  defp head_item(7, ai, arg, here, _depth, count, _position), do: simple(ai, arg, here, count)

  defp head_item(major, ai, {arg, rest}, here, depth, count, position) do
    if not shortest?(ai, arg), do: fail(:noncanonical, here)
    if position == :key and arg > @key_max, do: fail(:key_not_uint, here)
    value_item(major, arg, rest, here, depth, count)
  end

  # D11 to D16, by major type.
  defp value_item(major, arg, rest, here, depth, count) do
    case major do
      0 -> {arg, rest, count}
      1 when arg > @nint_arg_max -> fail(:int_out_of_range, here)
      1 -> {-1 - arg, rest, count}
      2 -> string(:bytes, arg, rest, here, count)
      3 -> string(:text, arg, rest, here, count)
      4 -> container(:array, arg, rest, here, depth + 1, count)
      5 -> container(:map, arg, rest, here, depth + 1, count)
    end
  end

  defp simple(20, {_, rest}, _here, count), do: {false, rest, count}
  defp simple(21, {_, rest}, _here, count), do: {true, rest, count}
  defp simple(22, {_, rest}, _here, count), do: {nil, rest, count}
  defp simple(ai, _arg, here, _count) when ai in 25..27, do: fail(:float_forbidden, here)
  defp simple(_ai, _arg, here, _count), do: fail(:simple_forbidden, here)

  # D4: the argument's bytes. A float's bytes are its argument here, so a truncated float is
  # `truncated` before it is `float_forbidden`.
  defp argument(ai, tail, _here) when ai < 24, do: {ai, tail}
  defp argument(24, <<v, rest::binary>>, _here), do: {v, rest}
  defp argument(25, <<v::16, rest::binary>>, _here), do: {v, rest}
  defp argument(26, <<v::32, rest::binary>>, _here), do: {v, rest}
  defp argument(27, <<v::64, rest::binary>>, _here), do: {v, rest}
  defp argument(_ai, _tail, here), do: fail(:truncated, here)

  defp shortest?(ai, _v) when ai < 24, do: true
  defp shortest?(24, v), do: v >= 24
  defp shortest?(25, v), do: v >= 0x100
  defp shortest?(26, v), do: v >= 0x1_0000
  defp shortest?(27, v), do: v >= 0x1_0000_0000

  # D13 compares the declared length with the bytes left (L > R), so it cannot overflow.
  defp string(_kind, len, rest, here, _count) when len > byte_size(rest),
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

  # D12: depth, then the fit check (the count against the bytes left divided by the smallest
  # element, never the count multiplied), then the item count. Nothing is read or reserved for a
  # declared count before all three pass.
  defp container(_kind, _n, _rest, here, depth, _count) when depth > @max_depth,
    do: fail(:too_deep, here)

  defp container(:array, n, rest, here, _depth, _count) when n > byte_size(rest),
    do: fail(:truncated, here)

  defp container(:map, n, rest, here, _depth, _count) when n > div(byte_size(rest), 2),
    do: fail(:truncated, here)

  defp container(kind, n, rest, here, depth, count) do
    count = count + if(kind == :map, do: 2 * n, else: n)
    if count > @max_items, do: fail(:too_many_items, here)

    case kind do
      :array -> elements(n, rest, depth, count, [])
      :map -> pairs(n, rest, depth, count, nil, [])
    end
  end

  defp elements(0, rest, _depth, count, acc), do: {Enum.reverse(acc), rest, count}

  defp elements(n, rest, depth, count, acc) do
    {value, rest, count} = item(rest, depth, count, :value)
    elements(n - 1, rest, depth, count, [value | acc])
  end

  defp pairs(0, rest, _depth, count, _prev, acc), do: {Map.new(acc), rest, count}

  defp pairs(n, rest, depth, count, prev, acc) do
    {key, after_key, count} = item(rest, depth, count, :key)
    key_bytes = binary_part(rest, 0, byte_size(rest) - byte_size(after_key))

    cond do
      prev == nil or key_bytes > prev -> :ok
      key_bytes == prev -> fail(:duplicate_key, rest)
      true -> fail(:noncanonical, rest)
    end

    {value, after_value, count} = item(after_key, depth, count, :value)
    pairs(n - 1, after_value, depth, count, key_bytes, [{key, value} | acc])
  end

  @spec fail(Profile.code(), binary()) :: no_return()
  defp fail(code, at), do: throw({:n6, code, at})
end
