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

  Slice 133: a second fake is a configuration away. `config :trinity, :memory, fake_dim:` (a
  multiple of 32; 384 by default) and `fake_seed:` (`""`) change the vectors and the space, so
  the suite can hold two spaces at once (a 384 and a 256, as AC2 asks on Postgres) and re-tier
  from one to the other.
  """
  @behaviour Trinity.Memory.Embedder

  alias Trinity.Memory.Space

  @impl true
  def dim, do: Keyword.get(config(), :fake_dim, 384)

  defp seed, do: Keyword.get(config(), :fake_seed, "")

  defp config, do: Application.get_env(:trinity, :memory, [])

  @impl true
  def model_id do
    case seed() do
      "" -> "fake:sha256-#{dim()}"
      seed -> "fake:sha256-#{dim()}-#{seed}"
    end
  end

  @impl true
  def availability, do: :ok

  @impl true
  def space do
    %{Space.legacy(model_id(), dim()) | locality: "in_process", runtime: "trinity-fake"}
  end

  @impl true
  def thresholds, do: %{floor: 0.3, dedupe: 0.92}

  @impl true
  def embed(texts), do: {:ok, Enum.map(texts, &vector/1)}

  @doc "The vector for one text, at the configured width and seed."
  @spec vector(String.t()) :: [float()]
  def vector(text), do: vector(text, dim(), seed())

  @doc "The vector for one text at a given width (a multiple of 32) and seed."
  @spec vector(String.t(), pos_integer(), String.t()) :: [float()]
  def vector(text, dim, salt) do
    {base, jitter} =
      case Regex.run(~r/^#near:(\S+)\s*(.*)$/s, text) do
        [_, key, rest] -> {key, byte_size(rest) * 0.01}
        _ -> {text, 0.0}
      end

    blocks = div(dim, 32) - 1

    floats =
      for i <- 0..blocks,
          <<b <- :crypto.hash(:sha256, <<i>> <> salt <> base)>>,
          do: b / 255.0 - 0.5

    floats = Enum.with_index(floats, fn f, i -> if i == 0, do: f + jitter, else: f end)
    norm = :math.sqrt(Enum.sum(Enum.map(floats, &(&1 * &1))))
    Enum.map(floats, &(&1 / norm))
  end
end
