# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Scorer do
  @moduledoc """
  Scoring int8 vectors in pure Elixir (slice 133, D-scoring): the path that needs no NIF.

  A stored vector of an int8 space is the L2-normalised embedding scaled so its largest
  component is 127 (`quantize/1`), one signed byte a dimension. Two ways to find the nearest:

  * **Exact**: the cosine of the int8 query with every row, `dot / (|q| * |d|)`, integers all the
    way until the one division. The dot runs over the two binaries eight bytes at a time, with
    no list built and no float boxed per element.
  * **Prefilter and rescore**: each row's sign bits (one bit a dimension, 32 bytes at 256d) are
    compared with the query's by Hamming distance, sixteen bits at a time through a 65,536-entry
    popcount table (OTP has no popcount BIF: erlang/otp#11371 is unmerged), and only the
    `candidates` nearest by Hamming are scored exactly. Faster on a prepared index, and
    approximate: a true neighbour whose signs disagree a lot can fall outside the candidates.

  AC13 measures both at 10^4 x 256 (`scripts/scorer_bench.exs`, docs/perf.md); over 50 ms p95
  opens the scoring-crate slice. Nothing here calls `nx`, `exla` or any NIF, which AC7's xref
  check holds for this module and everything it reaches.
  """
  import Bitwise

  @typedoc "A prepared row: its id, its int8 bytes, its squared norm and its sign bits."
  @type entry :: {term(), binary(), pos_integer() | 0, binary()}

  @pop16 List.to_tuple(for(x <- 0..65_535, do: x |> Integer.digits(2) |> Enum.sum()))

  @doc """
  A float vector as int8 bytes: scaled so its largest magnitude is 127, rounded. The zero
  vector stays zero.
  """
  @spec quantize([float()]) :: binary()
  def quantize(floats) do
    max = floats |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)

    if max == 0.0 do
      :binary.copy(<<0>>, length(floats))
    else
      for x <- floats, into: <<>>, do: <<round(x * 127 / max)::signed-8>>
    end
  end

  @doc "int8 bytes back to floats (unscaled: the cosine does not need the scale)."
  @spec to_floats(binary()) :: [float()]
  def to_floats(bin), do: for(<<x::signed-8 <- bin>>, do: x * 1.0)

  @doc "The integer dot product of two int8 vectors of the same length."
  @spec dot(binary(), binary()) :: integer()
  def dot(a, b) when byte_size(a) == byte_size(b), do: dot(a, b, 0)

  defp dot(
         <<a0::signed-8, a1::signed-8, a2::signed-8, a3::signed-8, a4::signed-8, a5::signed-8,
           a6::signed-8, a7::signed-8, ra::binary>>,
         <<b0::signed-8, b1::signed-8, b2::signed-8, b3::signed-8, b4::signed-8, b5::signed-8,
           b6::signed-8, b7::signed-8, rb::binary>>,
         acc
       ) do
    dot(
      ra,
      rb,
      acc + a0 * b0 + a1 * b1 + a2 * b2 + a3 * b3 + a4 * b4 + a5 * b5 + a6 * b6 + a7 * b7
    )
  end

  defp dot(<<a::signed-8, ra::binary>>, <<b::signed-8, rb::binary>>, acc),
    do: dot(ra, rb, acc + a * b)

  defp dot(<<>>, <<>>, acc), do: acc

  @doc "The squared norm of an int8 vector."
  @spec norm2(binary()) :: non_neg_integer()
  def norm2(a), do: dot(a, a, 0)

  @doc "The sign bits of an int8 vector: bit i is 1 when component i is not negative."
  @spec signs(binary()) :: binary()
  def signs(bin),
    do: for(<<x::signed-8 <- bin>>, into: <<>>, do: <<if(x >= 0, do: 1, else: 0)::1>>)

  @doc "The Hamming distance between two sign vectors of the same length (a multiple of 16 bits)."
  @spec hamming(binary(), binary()) :: non_neg_integer()
  def hamming(a, b), do: hamming(a, b, 0)

  defp hamming(<<x::16, ra::binary>>, <<y::16, rb::binary>>, acc),
    do: hamming(ra, rb, acc + elem(@pop16, bxor(x, y)))

  defp hamming(<<>>, <<>>, acc), do: acc

  @doc "Rows `{id, int8}` prepared for scoring: the squared norm and the sign bits computed once."
  @spec prepare([{term(), binary()}]) :: [entry()]
  def prepare(rows), do: Enum.map(rows, fn {id, v} -> {id, v, norm2(v), signs(v)} end)

  @doc "The cosine of an int8 query with an int8 row, from their dot and squared norms."
  @spec cosine(binary(), non_neg_integer(), binary(), non_neg_integer()) :: float()
  def cosine(q, qn2, d, dn2) do
    if qn2 == 0 or dn2 == 0, do: 0.0, else: dot(q, d, 0) / :math.sqrt(qn2 * dn2)
  end

  @doc """
  The `k` nearest prepared rows to an int8 query by exact int8 cosine, best first, as
  `{id, score}`. Ties are broken by id so the order is the same on every run.
  """
  @spec exact([entry()], binary(), pos_integer()) :: [{term(), float()}]
  def exact(index, q, k) do
    qn2 = norm2(q)

    index
    |> Enum.map(fn {id, d, dn2, _} -> {id, cosine(q, qn2, d, dn2)} end)
    |> top(k)
  end

  @doc """
  Prefilter and rescore: the `candidates` rows nearest to the query by Hamming distance over
  sign bits, then the exact int8 cosine over those alone; the `k` best, as `exact/3` returns
  them.
  """
  @spec prefilter([entry()], binary(), pos_integer(), pos_integer()) :: [{term(), float()}]
  def prefilter(index, q, k, candidates) do
    qs = signs(q)
    qn2 = norm2(q)

    index
    |> Enum.map(fn {_, _, _, s} = e -> {hamming(qs, s), e} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(candidates)
    |> Enum.map(fn {_, {id, d, dn2, _}} -> {id, cosine(q, qn2, d, dn2)} end)
    |> top(k)
  end

  defp top(scored, k) do
    scored
    |> Enum.sort(fn {ia, a}, {ib, b} -> a > b or (a == b and ia <= ib) end)
    |> Enum.take(k)
  end
end
