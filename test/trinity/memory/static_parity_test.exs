# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.StaticParityTest do
  @moduledoc """
  Slice 133, AC10: the static embedder's vectors match the reference implementation
  (sentence-transformers' `StaticEmbedding` over the upstream float32 weights) to cosine 0.9999
  or better on 500 fixtures, and a deliberately wrong pooling (sum rather than mean) fails.

  **Cosine alone cannot see the wrong pooling.** A sum over a bag is the mean times the number
  of tokens: the same direction, so the same cosine to anything. The comparison is therefore of
  the pooled vector before normalisation, as the reference returns it: its direction (cosine at
  or over 0.9999) and its length (within 0.5 % of the reference's). The red run of this file
  with the cosine check alone, where the sum passed, is in the slice's NOTES.

  The tolerance on length is the int8 quantization's: per-row int8 at 256 dimensions measured a
  norm ratio between 0.9983 and 1.0010 on these fixtures (NOTES); the float32 variant at 1024 is
  held to the same check and measures closer.
  """
  use ExUnit.Case, async: false

  alias Trinity.Memory.{Embedder, Embedders.Static}
  alias Trinity.StaticWeights

  @moduletag :static_weights
  @moduletag timeout: 300_000

  @min_cosine 0.9999
  @max_norm_error 0.005

  defp norm(v), do: :math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2)))

  @doc false
  def check(elixir, reference) do
    cos = Embedder.cosine(elixir, reference)
    ratio = norm(elixir) / norm(reference)
    {cos >= @min_cosine and abs(ratio - 1.0) <= @max_norm_error, cos, ratio}
  end

  defp failures(variant_key, pooling) do
    for %{"text" => text, ^variant_key => reference} <-
          StaticWeights.fixtures!("embeddings.jsonl"),
        {:ok, elixir} = Static.pooled_vector(text, pooling),
        {ok?, cos, ratio} = check(elixir, reference),
        not ok?,
        do: {text, cos, ratio}
  end

  describe "the 256-dimension int8 variant (the provisional default)" do
    setup do
      previous = StaticWeights.use_static!("256-int8")
      on_exit(fn -> StaticWeights.restore!(previous) end)
    end

    test "AC10: 500 fixtures, each at cosine >= 0.9999 with its length within 0.5 %" do
      rows = StaticWeights.fixtures!("embeddings.jsonl")
      assert length(rows) == 500

      stats =
        for %{"text" => t, "v256" => r, "ids" => ids} <- rows do
          {:ok, got_ids} = Static.token_ids(t)
          assert got_ids == ids, "token ids differ for #{inspect(t)}"
          {:ok, v} = Static.pooled_vector(t)
          check(v, r)
        end

      {min_cos, min_ratio, max_ratio} =
        {stats |> Enum.map(&elem(&1, 1)) |> Enum.min(),
         stats |> Enum.map(&elem(&1, 2)) |> Enum.min(),
         stats |> Enum.map(&elem(&1, 2)) |> Enum.max()}

      IO.puts(
        "\nAC10 256-int8: min cosine #{min_cos}, norm ratio #{min_ratio} to #{max_ratio} over 500"
      )

      assert Enum.all?(stats, &elem(&1, 0)),
             "#{Enum.count(stats, &(not elem(&1, 0)))} fixtures outside the check"
    end

    test "AC10 red: sum pooling fails the same check" do
      bad = failures("v256", :sum)
      IO.puts("\nAC10 red: sum pooling fails #{length(bad)} of 500")
      assert bad != []
      # It fails on length, never on direction: the case the cosine alone would have passed.
      assert Enum.all?(bad, fn {_, cos, ratio} -> cos >= @min_cosine and ratio > 1.0 end)
    end

    test "embed/1 is the pooled vector normalised, and a text with no tokens is the zero vector" do
      {:ok, [v]} = Static.embed(["The cat sat on the mat."])
      {:ok, p} = Static.pooled_vector("The cat sat on the mat.")
      assert_in_delta norm(v), 1.0, 1.0e-9
      assert_in_delta Embedder.cosine(v, p), 1.0, 1.0e-9
      assert length(v) == 256

      {:ok, [z]} = Static.embed(["\u200B\u0000"])
      assert Enum.all?(z, &(&1 == 0.0))
    end
  end

  describe "the 1024-dimension float32 variant (the eval's ceiling)" do
    setup do
      previous = StaticWeights.use_static!("1024-f32")
      on_exit(fn -> StaticWeights.restore!(previous) end)
    end

    test "AC10 at 1024 float32: 500 fixtures within the same check" do
      assert failures("v1024", :mean) == []
    end
  end
end
