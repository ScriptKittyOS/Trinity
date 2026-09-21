# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedders.Fake do
  @moduledoc """
  Deterministic vectors for the suite (slice 032): a text's SHA-256, taken twelve times
  with a counter, expanded to 384 floats (the local model's width, so the Postgres job's
  `vector(384)` column and index are the ones exercised) and L2-normalised. The same text
  embeds the same way in every run, and two different texts land near orthogonal (their
  cosine is a random walk over 384 signed bytes: within a few hundredths of zero). Texts that
  share a `#near:<key>` prefix map to nearby vectors (the key is what is hashed; the rest of
  the text only nudges one component), so a dedupe test has something to find.
  """
  @behaviour Trinity.Memory.Embedder

  @dim 384

  @impl true
  def dim, do: @dim

  @impl true
  def model_id, do: "fake:sha256-#{@dim}"

  @impl true
  def availability, do: :ok

  @impl true
  def embed(texts), do: {:ok, Enum.map(texts, &vector/1)}

  @doc "The vector for one text."
  @spec vector(String.t()) :: [float()]
  def vector(text) do
    {base, jitter} =
      case Regex.run(~r/^#near:(\S+)\s*(.*)$/s, text) do
        [_, key, rest] -> {key, byte_size(rest) * 0.01}
        _ -> {text, 0.0}
      end

    floats =
      for i <- 0..11, <<b <- :crypto.hash(:sha256, <<i>> <> base)>>, do: b / 255.0 - 0.5

    floats = Enum.with_index(floats, fn f, i -> if i == 0, do: f + jitter, else: f end)
    norm = :math.sqrt(Enum.sum(Enum.map(floats, &(&1 * &1))))
    Enum.map(floats, &(&1 / norm))
  end
end
