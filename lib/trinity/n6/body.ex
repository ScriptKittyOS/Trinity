# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Body do
  @moduledoc """
  The body rules of the N6 profile (draft v0.1-r7 section 3; slices 138 and 142): the shape every
  signed statement's body takes, checked against a declared schema.

  A body is a map. Key 0 is the schema version, an unsigned integer (major type 0 only), so it
  always encodes first. Within a known schema every key must be declared (there is no "ignore
  unknown" mode: a new field is a new schema version), every required key present, and every value
  of its declared type, range and grammar.

  An array is a sequence unless its field is declared a set. A set is encoded sorted by the encoded
  bytes of its elements, with no duplicates. The bytes alone cannot say which arrays are sets,
  which is why that check lives here and not in `Trinity.N6.CBOR`.

  ## Schemas

      %{kind: "trinity.test", version: 0x80000101, typ: "application/...+cose",
        fields: %{1 => {:issuer, {:tstr, 1, 255, :printable_ascii}, :required},
                  20 => {:tags, {:set, {:int, 0, 0xFFFFFFFF}}, :optional}}}

  `version` is the whole key-0 value. `typ`, when given, is the schema's one `typ` (B7).

  Types:

    * integers: `:uint` (0 to 2^64-1), `:int` (the profile's whole range), `{:int, min, max}`, and
      `{:enum, length, reserved_zero?}`, an index `0 <= i < length`, 0 refused when reserved;
    * strings: `:tstr` and `:bstr` (bounded only by the profile), `{:tstr, min, max, grammar}` with
      `grammar` one of `:any`, `:printable_ascii` (0x21 to 0x7E) or `:media_type` (r7 section 4),
      and `{:bstr, min, max}`; lengths are bytes;
    * `:bool`, `:any`, `:digest` (`Trinity.N6.Digest`), `:foreign_ref` (r7 section 4);
    * `{:array, type}`, `{:set, type}`, `{:tuple, [type]}` (an array of fixed shape),
      `{:map, fields}` (a nested map with no schema version), `{:one_of, [type]}` (the first whose
      CBOR type matches), and `{:nullable, type}`, the only place `null` is accepted.

  ## Order

  r7 section 3.6, steps B1 to B8, each answering the first failure: not a map (`body_not_map`); key
  0 missing (`schema_version_missing`), not an unsigned integer (`key_not_uint`), reserved
  (`schema_reserved`), in the shared test block outside a declared test mode
  (`test_schema_outside_test_mode`), not issued (`unknown_schema`); presented under a `typ` that is
  not the schema's (`typ_schema_mismatch`, B7, only when a `typ` is given); then **one scan** over
  the keys present and the keys required, in ascending order (B8). At each key: required and
  absent is `issuer_missing` for the top level's key 1 and `field_missing` otherwise; present and
  undeclared is `unknown_key`; present and declared is checked by its type: the CBOR type
  (`field_type_mismatch`), then range, length or enum index (`value_out_of_range`), then grammar
  (`text_grammar_mismatch`), then a set's order (`set_not_canonical`, each element checked as the
  scan reaches it and then compared with the previous one), then a nested map by the same scan.
  """

  alias Trinity.N6.{CBOR, Digest, Profile}

  @reserved 0xFFFF_0000..0xFFFF_FFFF
  @uint64_max 0xFFFF_FFFF_FFFF_FFFF
  @int64_min -0x8000_0000_0000_0000

  @typedoc "A field type."
  @type type ::
          :uint
          | :int
          | {:int, integer(), integer()}
          | {:enum, pos_integer(), boolean()}
          | :tstr
          | {:tstr, non_neg_integer(), non_neg_integer(), :any | :printable_ascii | :media_type}
          | :bstr
          | {:bstr, non_neg_integer(), non_neg_integer()}
          | :bool
          | :any
          | :digest
          | :foreign_ref
          | {:array, type()}
          | {:set, type()}
          | {:tuple, [type()]}
          | {:map, %{optional(non_neg_integer()) => field()}}
          | {:one_of, [type()]}
          | {:nullable, type()}

  @typedoc "A field: its name, its type, and whether it must be present."
  @type field :: {atom(), type(), :required | :optional}

  @typedoc "A schema: one statement kind at one schema version."
  @type schema :: %{
          required(:kind) => String.t(),
          required(:version) => non_neg_integer(),
          required(:fields) => %{optional(pos_integer()) => field()},
          optional(:typ) => String.t()
        }

  # r7 section 4: ForeignRef = {0: Digest, 1: length, 2: media type, ? 3: locator}.
  @foreign_ref_fields %{
    0 => {:digest, :digest, :required},
    1 => {:length, :uint, :required},
    2 => {:media_type, {:tstr, 1, 255, :media_type}, :required},
    3 => {:locator, {:tstr, 1, 2048, :printable_ascii}, :optional}
  }

  @doc """
  Decodes bytes as a body of `kind` under one of `schemas`: the strict decode of
  `Trinity.N6.CBOR` (every section 2 code first), then `check/4`. `opts` as `check/4` takes them.
  """
  @spec decode(binary(), String.t() | :any, [schema()], keyword()) ::
          {:ok, map(), schema()} | {:error, Profile.code(), non_neg_integer() | nil}
  def decode(bytes, kind, schemas, opts \\ []) when is_binary(bytes) do
    with {:ok, value} <- CBOR.decode(bytes),
         {:ok, schema} <- check(value, kind, schemas, opts) do
      {:ok, value, schema}
    else
      {:error, code, offset} -> {:error, code, offset}
      {:error, code} -> {:error, code, nil}
    end
  end

  @doc """
  Encodes a body after checking it, so a body this tree builds is one it would accept. The
  decode limits apply too: a body that could not be read back is not built.
  """
  @spec encode(map(), String.t() | :any, [schema()], keyword()) ::
          {:ok, binary()} | {:error, Profile.code()}
  def encode(value, kind, schemas, opts \\ []) do
    with {:ok, _schema} <- check(value, kind, schemas, opts),
         {:ok, bytes} <- CBOR.encode(value),
         {:ok, _} <- CBOR.decode(bytes) do
      {:ok, bytes}
    else
      {:error, code, _offset} -> {:error, code}
      {:error, code} -> {:error, code}
    end
  end

  @doc """
  Checks a decoded value against the body rules and the schema its key 0 names. `kind` narrows
  the schemas to one statement kind, or is `:any`. `opts`: `test_mode: true` admits the shared test
  block (0x80), which every other verifier refuses; `typ:` is the `typ` the body is presented
  under, which runs B7.
  """
  @spec check(CBOR.value(), String.t() | :any, [schema()], keyword()) ::
          {:ok, schema()} | {:error, Profile.code()}
  def check(value, kind, schemas, opts \\ [])

  def check(value, _kind, _schemas, _opts) when not is_map(value), do: {:error, :body_not_map}

  def check(value, kind, schemas, opts) do
    with {:ok, version} <- version(value),
         :ok <- test_mode(version, Keyword.get(opts, :test_mode, false)),
         {:ok, schema} <- schema(kind, version, schemas),
         :ok <- typ(schema, Keyword.get(opts, :typ)),
         :ok <- scan(Map.delete(value, 0), schema.fields, :top) do
      {:ok, schema}
    end
  end

  @doc """
  Checks one decoded value against one field type, by the B8 rules (`:foreign_ref` included):
  what a ForeignRef or a field is checked by when it is judged on its own.
  """
  @spec check_value(CBOR.value(), type()) :: :ok | {:error, Profile.code()}
  def check_value(v, type), do: value(v, type)

  defp version(%{0 => v}) when is_integer(v) and v in @reserved, do: {:error, :schema_reserved}
  defp version(%{0 => v}) when is_integer(v) and v >= 0, do: {:ok, v}
  defp version(%{0 => _}), do: {:error, :key_not_uint}
  defp version(_), do: {:error, :schema_version_missing}

  defp test_mode(version, false) do
    if Profile.test_schema?(version), do: {:error, :test_schema_outside_test_mode}, else: :ok
  end

  defp test_mode(_version, true), do: :ok

  defp schema(kind, version, schemas) do
    case Enum.find(schemas, &(&1.version == version and (kind == :any or &1.kind == kind))) do
      nil -> {:error, :unknown_schema}
      schema -> {:ok, schema}
    end
  end

  defp typ(_schema, nil), do: :ok
  defp typ(%{typ: typ}, typ), do: :ok
  defp typ(_schema, _typ), do: {:error, :typ_schema_mismatch}

  # B8: one ascending scan over the union of the keys present and the keys required.
  defp scan(map, fields, level) do
    required = for {key, {_name, _type, :required}} <- fields, do: key

    (Map.keys(map) ++ required)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find_value(:ok, fn key ->
      case at_key(map, fields, key, level) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp at_key(map, fields, key, level) do
    case {Map.fetch(map, key), Map.fetch(fields, key)} do
      {:error, _required} when key == 1 and level == :top -> {:error, :issuer_missing}
      {:error, _required} -> {:error, :field_missing}
      {{:ok, _v}, :error} -> {:error, :unknown_key}
      {{:ok, v}, {:ok, {_name, type, _presence}}} -> value(v, type)
    end
  end

  # One value, in the order r7 section 3.6 gives: type, then range, then grammar, then a set's
  # order, then what a nested structure holds.
  defp value(nil, {:nullable, _type}), do: :ok
  defp value(v, {:nullable, type}), do: value(v, type)

  defp value(v, {:one_of, types}) do
    case Enum.find(types, &type_matches?(v, &1)) do
      nil -> {:error, :field_type_mismatch}
      type -> value(v, type)
    end
  end

  defp value(v, :digest), do: Digest.check(v)

  defp value(v, :foreign_ref) when is_map(v), do: scan(v, @foreign_ref_fields, :nested)

  defp value(items, {:array, type}) when is_list(items), do: each(items, type)

  defp value(items, {:set, type}) when is_list(items), do: set(items, type, nil)

  defp value(items, {:tuple, types}) when is_list(items) and length(items) == length(types),
    do: items |> Enum.zip(types) |> first_error(fn {v, t} -> value(v, t) end)

  defp value(_v, {:tuple, _types}), do: {:error, :field_type_mismatch}

  defp value(map, {:map, nested}) when is_map(map), do: scan(map, nested, :nested)

  defp value(v, type) do
    cond do
      not type_matches?(v, type) -> {:error, :field_type_mismatch}
      not in_range?(v, type) -> {:error, :value_out_of_range}
      not grammar?(v, type) -> {:error, :text_grammar_mismatch}
      true -> :ok
    end
  end

  defp each(items, type), do: first_error(items, &value(&1, type))

  # Each element is checked as the scan reaches it, then compared with the previous one, so
  # `[5, 3, 2^32]` is `set_not_canonical` at 3 and `[2^32, 3]` is out of range at the first.
  defp set([], _type, _prev), do: :ok

  defp set([item | rest], type, prev) do
    with :ok <- value(item, type) do
      bytes = CBOR.encode!(item)

      if prev == nil or bytes > prev,
        do: set(rest, type, bytes),
        else: {:error, :set_not_canonical}
    end
  end

  defp first_error(items, fun) do
    Enum.find_value(items, :ok, fn item ->
      case fun.(item) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp type_matches?(nil, {:nullable, _}), do: true
  defp type_matches?(v, {:nullable, type}), do: type_matches?(v, type)
  defp type_matches?(v, {:one_of, types}), do: Enum.any?(types, &type_matches?(v, &1))
  defp type_matches?(v, type), do: cbor_type(v) == base(type) or base(type) == :any

  defp cbor_type(v) when is_integer(v), do: :int
  defp cbor_type(v) when is_boolean(v), do: :bool
  defp cbor_type({:text, _}), do: :text
  defp cbor_type({:bytes, _}), do: :bytes
  defp cbor_type(v) when is_list(v), do: :array
  defp cbor_type(v) when is_map(v), do: :map
  defp cbor_type(nil), do: :null

  defp base(type) when type in [:uint, :int], do: :int
  defp base({kind, _, _}) when kind in [:int, :enum], do: :int
  defp base(:tstr), do: :text
  defp base({:tstr, _, _, _}), do: :text
  defp base(:bstr), do: :bytes
  defp base({:bstr, _, _}), do: :bytes
  defp base(:bool), do: :bool
  defp base(:any), do: :any
  defp base(:digest), do: :array
  defp base({kind, _}) when kind in [:array, :set, :tuple], do: :array
  defp base(:foreign_ref), do: :map
  defp base({:map, _}), do: :map

  defp in_range?(v, :uint), do: v >= 0 and v <= @uint64_max
  defp in_range?(v, :int), do: v >= @int64_min and v <= @uint64_max
  defp in_range?(v, {:int, min, max}), do: v >= min and v <= max

  defp in_range?(v, {:enum, length, reserved_zero?}),
    do: v >= 0 and v < length and not (reserved_zero? and v == 0)

  defp in_range?({_, s}, {kind, min, max, _grammar}) when kind == :tstr,
    do: byte_size(s) in min..max//1

  defp in_range?({_, s}, {:bstr, min, max}), do: byte_size(s) in min..max//1
  defp in_range?(_v, _type), do: true

  defp grammar?({:text, s}, {:tstr, _min, _max, :printable_ascii}), do: printable_ascii?(s)
  defp grammar?({:text, s}, {:tstr, _min, _max, :media_type}), do: media_type?(s)
  defp grammar?(_v, _type), do: true

  defp printable_ascii?(s), do: s |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

  @doc """
  Whether text is a media type under r7 section 4's grammar: `type "/" subtype`, lowercase, no
  parameters, each part `[a-z0-9][a-z0-9!#$&^_.+-]{0,126}`.
  """
  @spec media_type?(binary()) :: boolean()
  def media_type?(s) do
    case :binary.split(s, "/", [:global]) do
      [type, subtype] -> media_part?(type) and media_part?(subtype)
      _ -> false
    end
  end

  defp media_part?(<<first, rest::binary>>) when byte_size(rest) <= 126,
    do: media_first?(first) and rest |> :binary.bin_to_list() |> Enum.all?(&media_rest?/1)

  defp media_part?(_), do: false

  defp media_first?(c), do: c in ?a..?z or c in ?0..?9
  defp media_rest?(c), do: media_first?(c) or c in ~c"!#$&^_.+-"
end
