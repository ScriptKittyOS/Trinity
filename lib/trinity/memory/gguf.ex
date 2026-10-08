# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.GGUF do
  @moduledoc """
  Reads a GGUF file's metadata (slice 134): the key/value header llama.cpp and Ollama read before
  the tensors. Trinity needs it once, at import, to take the tokenizer out of verified weights
  (`Trinity.Memory.Tier3.Import`); it never reads the tensors.

  The format (GGUF version 2 and 3, little-endian): the magic `GGUF`, a `u32` version, a `u64`
  tensor count, a `u64` key/value count, then each pair: the key as a string (a `u64` length and
  the bytes), a `u32` value type and the value. Types: 0 `u8`, 1 `i8`, 2 `u16`, 3 `i16`, 4 `u32`,
  5 `i32`, 6 `f32`, 7 `bool`, 8 string, 9 array (a `u32` element type, a `u64` count, the
  elements), 10 `u64`, 11 `i64`, 12 `f64`.

  The header is read from the start of the file in growing pieces, so a 1 GB file costs only
  the few megabytes its metadata takes. Anything the format does not allow (another magic, an
  unknown type, a length past the file) is `{:error, reason}`, never a guess.
  """

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @first_read 4 * 1024 * 1024
  @max_header 512 * 1024 * 1024

  @type value :: integer() | float() | boolean() | String.t() | [value()]

  @doc "The metadata of the GGUF file at `path`, as a map from key to value."
  @spec metadata(Path.t()) :: {:ok, %{String.t() => value()}} | {:error, term()}
  def metadata(path) do
    with {:ok, io} <- open(path) do
      try do
        read_growing(io, @first_read)
      after
        File.close(io)
      end
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the path is the operator's own weights file, given
  # to the import task on its command line, opened read-only after its signatures were verified.
  @sobelow_skip ["Traversal.FileModule"]
  defp open(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp read_growing(io, size) do
    case :file.pread(io, 0, size) do
      {:ok, bin} ->
        case parse(bin) do
          {:error, :truncated} when byte_size(bin) == size and size < @max_header ->
            read_growing(io, size * 4)

          other ->
            other
        end

      :eof ->
        {:error, :empty}

      {:error, reason} ->
        {:error, {:unreadable, reason}}
    end
  end

  @doc """
  Parses the metadata from the start of a GGUF file held in `bin` (which may stop anywhere after
  the header). `{:error, :truncated}` when the header runs past the end of `bin`.
  """
  @spec parse(binary()) :: {:ok, %{String.t() => value()}} | {:error, term()}
  def parse(<<"GGUF", version::little-32, _tensors::little-64, count::little-64, rest::binary>>)
      when version in [2, 3] do
    pairs(rest, count, %{})
  catch
    :truncated -> {:error, :truncated}
    {:bad, reason} -> {:error, reason}
  end

  def parse(<<"GGUF", version::little-32, _::binary>>),
    do: {:error, {:unsupported_version, version}}

  def parse(bin) when byte_size(bin) < 24, do: {:error, :truncated}
  def parse(_), do: {:error, :not_gguf}

  defp pairs(_rest, 0, acc), do: {:ok, acc}

  defp pairs(bin, n, acc) do
    {key, bin} = string(bin)
    {type, bin} = u32(bin)
    {value, bin} = value(type, bin)
    pairs(bin, n - 1, Map.put(acc, key, value))
  end

  defp u32(<<v::little-32, rest::binary>>), do: {v, rest}
  defp u32(_), do: throw(:truncated)

  defp string(<<len::little-64, rest::binary>>) do
    case rest do
      <<s::binary-size(^len), rest::binary>> -> {s, rest}
      _ when len > @max_header -> throw({:bad, {:string_too_long, len}})
      _ -> throw(:truncated)
    end
  end

  defp string(_), do: throw(:truncated)

  defp value(0, <<v::little-unsigned-8, r::binary>>), do: {v, r}
  defp value(1, <<v::little-signed-8, r::binary>>), do: {v, r}
  defp value(2, <<v::little-unsigned-16, r::binary>>), do: {v, r}
  defp value(3, <<v::little-signed-16, r::binary>>), do: {v, r}
  defp value(4, <<v::little-unsigned-32, r::binary>>), do: {v, r}
  defp value(5, <<v::little-signed-32, r::binary>>), do: {v, r}
  defp value(6, <<v::little-float-32, r::binary>>), do: {v, r}
  defp value(7, <<v::8, r::binary>>), do: {v != 0, r}
  defp value(8, bin), do: string(bin)
  defp value(10, <<v::little-unsigned-64, r::binary>>), do: {v, r}
  defp value(11, <<v::little-signed-64, r::binary>>), do: {v, r}
  defp value(12, <<v::little-float-64, r::binary>>), do: {v, r}

  defp value(9, <<type::little-32, count::little-64, rest::binary>>) do
    if type == 9, do: throw({:bad, :nested_array})
    if count > @max_header, do: throw({:bad, {:array_too_long, count}})
    array(type, count, rest, [])
  end

  defp value(type, _bin) when type in 0..12, do: throw(:truncated)
  defp value(type, _bin), do: throw({:bad, {:unknown_type, type}})

  defp array(_type, 0, rest, acc), do: {Enum.reverse(acc), rest}

  defp array(type, n, bin, acc) do
    {v, rest} = value(type, bin)
    array(type, n - 1, rest, [v | acc])
  end
end
