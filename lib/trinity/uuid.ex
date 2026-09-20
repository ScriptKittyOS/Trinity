# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.UUID do
  @moduledoc """
  UUIDv7 (RFC 9562 section 5.7), generated in-tree. Slice 010.

  Layout, most significant first: 48 bits of Unix milliseconds; 4 bits version `0111`; 12 bits
  `rand_a`; 2 bits variant `10`; 62 bits `rand_b`. `rand_a` carries the low twelve bits of a
  VM-wide monotonic counter (RFC 9562 section 6.2, method 1), so ids minted within one
  millisecond sort in the order they were minted; `rand_b` is random on every call, so two
  ids can never be equal even if the counter wrapped inside a millisecond, which takes more
  than 4096 mints in that millisecond. Beyond that rate the order within the millisecond is
  no longer guaranteed and uniqueness still is.

  Every primary key in the tree uses this so rows sort by creation time without a second
  column. The module is also an `Ecto.Type` of underlying type `:uuid`, delegating cast,
  dump and load to `Ecto.UUID` so each adapter keeps its own storage rule (text on SQLite,
  `uuid` on Postgres, with `:binary_id` migration columns), and supplying `autogenerate/0`
  so a schema declares `@primary_key {:id, Trinity.UUID, autogenerate: true}`.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :uuid

  @impl Ecto.Type
  def cast(value), do: Ecto.UUID.cast(value)

  @impl Ecto.Type
  def dump(value), do: Ecto.UUID.dump(value)

  @impl Ecto.Type
  def load(value), do: Ecto.UUID.load(value)

  @impl Ecto.Type
  def autogenerate, do: generate()

  @doc "A new UUIDv7 in the canonical 36-character string form."
  @spec generate() :: String.t()
  def generate do
    ms = System.system_time(:millisecond)
    seq = :erlang.unique_integer([:monotonic, :positive])
    <<rand_b::62, _::2>> = :crypto.strong_rand_bytes(8)

    encode(<<ms::48, 7::4, seq::12, 2::2, rand_b::62>>)
  end

  @doc "The Unix millisecond timestamp an id carries."
  @spec timestamp_ms(String.t()) :: {:ok, non_neg_integer()} | :error
  def timestamp_ms(<<_::binary-size(36)>> = uuid) do
    case Base.decode16(String.replace(uuid, "-", ""), case: :mixed) do
      {:ok, <<ms::48, 7::4, _::76>>} -> {:ok, ms}
      _ -> :error
    end
  end

  def timestamp_ms(_), do: :error

  defp encode(<<a::32, b::16, c::16, d::16, e::48>>) do
    [<<a::32>>, <<b::16>>, <<c::16>>, <<d::16>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
