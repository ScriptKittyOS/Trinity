# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.StaticArtifact do
  @moduledoc """
  The static embedder's weights file (slice 133): one file holding the vocabulary and the
  embedding matrix, derived deterministically from the upstream model at a pinned revision by
  `mix trinity.static.build`, so its SHA-256 can be pinned in code and checked at load.

  Layout, all integers little-endian:

      "TSW1"                       magic, 4 bytes
      header_len :: 32             then the header, RFC 8785 JSON: model, revision, the upstream
                                   files' SHA-256, rows, dim, quantization, source_dim
      vocab_len :: 32              then the vocabulary, one token per line, line n is id n
      scales                       int8 only: rows x float32, one scale per row
      matrix                       rows x dim, int8 (q = round(x / scale), scale = max|x| / 127)
                                   or float32

  Truncation to `dim` is the first `dim` columns, which is what Matryoshka truncation is and what
  sentence-transformers' `truncate_dim` does. The int8 scale is per row (per token), so one
  large-valued token does not crush the precision of the rest.
  """

  @magic "TSW1"

  @enforce_keys [:header, :vocab, :rows, :dim, :quantization, :scales, :matrix]
  defstruct @enforce_keys

  @type quantization :: :int8 | :f32
  @type t :: %__MODULE__{
          header: map(),
          vocab: [String.t()],
          rows: pos_integer(),
          dim: pos_integer(),
          quantization: quantization(),
          scales: binary() | nil,
          matrix: binary()
        }

  @doc """
  Builds the file's bytes from a float32 row-major matrix (`source_dim` columns), the vocabulary
  and the provenance header fields. Deterministic: the same inputs give the same bytes.
  """
  @spec build(binary(), pos_integer(), pos_integer(), [String.t()], keyword()) :: binary()
  def build(f32_matrix, rows, source_dim, vocab, opts) do
    dim = Keyword.fetch!(opts, :dim)
    quantization = Keyword.fetch!(opts, :quantization)

    unless byte_size(f32_matrix) == rows * source_dim * 4 and dim <= source_dim and
             length(vocab) == rows do
      raise ArgumentError, "the matrix, the vocabulary and the dimensions do not agree"
    end

    truncated = for r <- 0..(rows - 1), do: binary_part(f32_matrix, r * source_dim * 4, dim * 4)

    {scales, matrix} =
      case quantization do
        :f32 -> {"", IO.iodata_to_binary(truncated)}
        :int8 -> quantize(truncated)
      end

    header =
      opts
      |> Keyword.get(:provenance, %{})
      |> Map.merge(%{
        "rows" => rows,
        "dim" => dim,
        "quantization" => Atom.to_string(quantization),
        "source_dim" => source_dim
      })
      |> Jcs.encode()

    vocab_bin = Enum.join(vocab, "\n")

    IO.iodata_to_binary([
      @magic,
      <<byte_size(header)::32-little>>,
      header,
      <<byte_size(vocab_bin)::32-little>>,
      vocab_bin,
      scales,
      matrix
    ])
  end

  defp quantize(rows) do
    {scales, qs} = rows |> Enum.map(&quantize_row/1) |> Enum.unzip()
    {IO.iodata_to_binary(scales), IO.iodata_to_binary(qs)}
  end

  # One row: its scale (as the file stores it, float32, so quantizing and dequantizing agree)
  # and its bytes.
  defp quantize_row(row) do
    floats = for <<x::float-little-32 <- row>>, do: x
    max = floats |> Enum.map(&abs/1) |> Enum.max()
    <<scale::float-little-32>> = <<if(max == 0.0, do: 0.0, else: max / 127)::float-little-32>>
    {<<scale::float-little-32>>, for(x <- floats, into: <<>>, do: <<q8(x, scale)::signed-8>>)}
  end

  defp q8(_x, scale) when scale == 0.0, do: 0
  defp q8(x, scale), do: x |> Kernel./(scale) |> round() |> max(-127) |> min(127)

  @doc "Parses the file's bytes. `{:error, reason}` for anything that is not a whole artifact."
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(<<@magic, hlen::32-little, rest::binary>>) when byte_size(rest) >= hlen do
    <<header_json::binary-size(^hlen), rest::binary>> = rest

    with {:ok, header} <- Jason.decode(header_json),
         %{"rows" => rows, "dim" => dim, "quantization" => q} when is_integer(rows) <- header,
         <<vlen::32-little, rest::binary>> when byte_size(rest) >= vlen <- rest,
         <<vocab_bin::binary-size(^vlen), rest::binary>> <- rest,
         {:ok, quantization} <- quantization(q),
         {:ok, scales, matrix} <- split_tables(rest, rows, dim, quantization) do
      vocab = String.split(vocab_bin, "\n")

      if length(vocab) == rows,
        do:
          {:ok,
           %__MODULE__{
             header: header,
             vocab: vocab,
             rows: rows,
             dim: dim,
             quantization: quantization,
             scales: scales,
             matrix: matrix
           }},
        else: {:error, :vocab_rows_mismatch}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def parse(_), do: {:error, :not_an_artifact}

  defp quantization("int8"), do: {:ok, :int8}
  defp quantization("f32"), do: {:ok, :f32}
  defp quantization(other), do: {:error, {:unknown_quantization, other}}

  defp split_tables(rest, rows, dim, :int8) do
    {s, m} = {rows * 4, rows * dim}

    case rest do
      <<scales::binary-size(^s), matrix::binary-size(^m)>> -> {:ok, scales, matrix}
      _ -> {:error, :truncated}
    end
  end

  defp split_tables(rest, rows, dim, :f32) do
    m = rows * dim * 4

    case rest do
      <<matrix::binary-size(^m)>> -> {:ok, nil, matrix}
      _ -> {:error, :truncated}
    end
  end

  @doc "The row for a token id as floats (dequantized for int8)."
  @spec row(t(), non_neg_integer()) :: [float()]
  def row(%__MODULE__{quantization: :int8, dim: dim, scales: scales, matrix: m}, id) do
    <<scale::float-little-32>> = binary_part(scales, id * 4, 4)
    for <<q::signed-8 <- binary_part(m, id * dim, dim)>>, do: q * scale
  end

  def row(%__MODULE__{quantization: :f32, dim: dim, matrix: m}, id) do
    for <<x::float-little-32 <- binary_part(m, id * dim * 4, dim * 4)>>, do: x
  end

  @doc """
  Reads the float32 matrix out of a `model.safetensors` holding exactly one 2-D F32 tensor (the
  static model's `embedding.weight`). `{:ok, matrix, rows, cols}`.
  """
  @spec read_safetensors(binary()) ::
          {:ok, binary(), pos_integer(), pos_integer()} | {:error, term()}
  def read_safetensors(<<hlen::64-little, rest::binary>>) when byte_size(rest) >= hlen do
    <<header::binary-size(^hlen), data::binary>> = rest

    with {:ok, h} <- Jason.decode(header),
         [{_name, %{"dtype" => "F32", "shape" => [rows, cols], "data_offsets" => [from, to]}}] <-
           Enum.reject(h, fn {k, _} -> k == "__metadata__" end),
         true <- to - from == rows * cols * 4 and byte_size(data) >= to do
      {:ok, binary_part(data, from, to - from), rows, cols}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unexpected_safetensors_layout}
    end
  end

  def read_safetensors(_), do: {:error, :not_safetensors}
end
