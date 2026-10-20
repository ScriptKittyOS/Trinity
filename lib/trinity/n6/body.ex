# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Body do
  @moduledoc """
  The body rules of the N6 profile (its section 3; slice 138): the shape every signed statement's
  body takes, checked against a declared schema.

  A body is a map. Key 0 is the schema version, an unsigned integer (major type 0 only), so it
  always encodes first. The pair of statement kind and schema version must be one the caller
  declares; within it every key must be declared (there is no "ignore unknown" mode: a new field is
  a new schema version), every required key present, and every value of its declared type. Key 0
  values 0xFFFF0000 to 0xFFFFFFFF are reserved for carrier structures and are refused in a body.

  An array is a sequence unless its field is declared a set. A set is encoded sorted by the encoded
  bytes of its elements, with no duplicates. The bytes alone cannot say which arrays are sets,
  which is why that check lives here and not in `Trinity.N6.CBOR`.

  ## Schemas

      %{kind: "trinity.test", version: 1,
        fields: %{16 => {:name, :tstr, :required}, 18 => {:members, {:set, :uint}, :optional}}}

  Types: `:uint`, `:int`, `:tstr`, `:bstr`, `:bool`, `:any`, `{:array, type}`, `{:set, type}`,
  `:digest` (`Trinity.N6.Digest`), and `{:map, fields}` for a nested map with no schema version.

  Checks run in this order, each answering the first failure: not a map (`body_not_map`); key 0
  missing (`schema_version_missing`), not an unsigned integer (`key_not_uint`), reserved
  (`schema_reserved`), unknown with this kind (`unknown_schema`); then keys in ascending order,
  undeclared (`unknown_key`); then required keys (`required_key_missing`); then each value in key
  order (`wrong_type`, `set_not_canonical`, or a digest's own code). `body_not_map`,
  `required_key_missing` and `wrong_type` are this tree's codes where the profile has none yet.
  """

  alias Trinity.N6.{CBOR, Digest, Profile}

  @reserved 0xFFFF_0000..0xFFFF_FFFF

  @typedoc "A field type."
  @type type ::
          :uint
          | :int
          | :tstr
          | :bstr
          | :bool
          | :any
          | :digest
          | {:array, type()}
          | {:set, type()}
          | {:map, %{optional(non_neg_integer()) => field()}}

  @typedoc "A field: its name, its type, and whether it must be present."
  @type field :: {atom(), type(), :required | :optional}

  @typedoc "A schema: one statement kind at one schema version."
  @type schema :: %{
          kind: String.t(),
          version: non_neg_integer(),
          fields: %{optional(pos_integer()) => field()}
        }

  @doc """
  Decodes bytes as a body of `kind` under one of `schemas`: the strict decode of
  `Trinity.N6.CBOR`, then `check/3`.
  """
  @spec decode(binary(), String.t(), [schema()]) ::
          {:ok, map(), schema()} | {:error, Profile.code(), non_neg_integer() | nil}
  def decode(bytes, kind, schemas) when is_binary(bytes) do
    with {:ok, value} <- CBOR.decode(bytes),
         {:ok, schema} <- check(value, kind, schemas) do
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
  @spec encode(map(), String.t(), [schema()]) :: {:ok, binary()} | {:error, Profile.code()}
  def encode(value, kind, schemas) do
    with {:ok, _schema} <- check(value, kind, schemas),
         {:ok, bytes} <- CBOR.encode(value),
         {:ok, _} <- CBOR.decode(bytes) do
      {:ok, bytes}
    else
      {:error, code, _offset} -> {:error, code}
      {:error, code} -> {:error, code}
    end
  end

  @doc "Checks a decoded value against the body rules and the schema its key 0 names."
  @spec check(CBOR.value(), String.t(), [schema()]) :: {:ok, schema()} | {:error, Profile.code()}
  def check(value, _kind, _schemas) when not is_map(value), do: {:error, :body_not_map}

  def check(value, kind, schemas) do
    with {:ok, version} <- version(value),
         {:ok, schema} <- schema(kind, version, schemas),
         :ok <- fields(Map.delete(value, 0), schema.fields) do
      {:ok, schema}
    end
  end

  # Key 0 is the schema version at the top level only; a nested map has no version key, so every
  # key it holds is checked against its fields.
  defp fields(map, fields) do
    with :ok <- known_keys(map, fields),
         :ok <- required(map, fields),
         do: types(map, fields)
  end

  defp version(%{0 => v}) when is_integer(v) and v in @reserved, do: {:error, :schema_reserved}
  defp version(%{0 => v}) when is_integer(v) and v >= 0, do: {:ok, v}
  defp version(%{0 => _}), do: {:error, :key_not_uint}
  defp version(_), do: {:error, :schema_version_missing}

  defp schema(kind, version, schemas) do
    case Enum.find(schemas, &(&1.kind == kind and &1.version == version)) do
      nil -> {:error, :unknown_schema}
      schema -> {:ok, schema}
    end
  end

  defp known_keys(value, fields) do
    case value |> Map.keys() |> Enum.sort() |> Enum.find(&(not is_map_key(fields, &1))) do
      nil -> :ok
      _key -> {:error, :unknown_key}
    end
  end

  defp required(value, fields) do
    missing = for {key, {_name, _type, :required}} <- fields, not is_map_key(value, key), do: key
    if missing == [], do: :ok, else: {:error, :required_key_missing}
  end

  defp types(value, fields) do
    value
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, v} ->
      {_name, type, _presence} = Map.fetch!(fields, key)

      case of_type(v, type) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp of_type(v, :uint) when is_integer(v) and v >= 0, do: :ok
  defp of_type(v, :int) when is_integer(v), do: :ok
  defp of_type({:text, _}, :tstr), do: :ok
  defp of_type({:bytes, _}, :bstr), do: :ok
  defp of_type(v, :bool) when is_boolean(v), do: :ok
  defp of_type(_v, :any), do: :ok

  defp of_type(v, :digest) do
    case Digest.check(v) do
      :ok -> :ok
      {:error, code} -> {:error, code}
    end
  end

  defp of_type(items, {:array, type}) when is_list(items), do: all_of(items, type)

  defp of_type(items, {:set, type}) when is_list(items) do
    with :ok <- all_of(items, type), do: canonical_set(items)
  end

  defp of_type(map, {:map, nested}) when is_map(map), do: fields(map, nested)

  defp of_type(_v, _type), do: {:error, :wrong_type}

  defp all_of(items, type) do
    Enum.find_value(items, :ok, fn item ->
      case of_type(item, type) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp canonical_set(items) do
    encoded = Enum.map(items, &CBOR.encode!/1)

    strictly_ascending? =
      encoded |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)

    if strictly_ascending?, do: :ok, else: {:error, :set_not_canonical}
  end
end
