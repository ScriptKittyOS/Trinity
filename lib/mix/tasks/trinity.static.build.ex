# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Static.Build do
  @shortdoc "Builds the static embedder's weights artifact from a local model snapshot"

  @moduledoc """
  Slice 133. Reads a local snapshot of `sentence-transformers/static-retrieval-mrl-en-v1` (the
  directory holding `0_StaticEmbedding/model.safetensors` and `tokenizer.json`), checks both
  files against the SHA-256 pinned for the revision in `Trinity.Memory.Embedders.Static`, checks
  the tokenizer is the BERT uncased pipeline `Trinity.Memory.WordPiece` implements, and writes
  the artifact for a variant (`256-int8` by default, `1024-f32` for the eval's ceiling). Offline:
  it reads files and makes no request. Prints the artifact's SHA-256, which must equal the digest
  pinned for the variant.

      mix trinity.static.build --snapshot <dir> --out <dir> [--variant 256-int8]

  The weights it reads and writes are not part of this tree (slice 133 NOTES, D7).
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  alias Trinity.Memory.Embedders.Static
  alias Trinity.Memory.StaticArtifact

  @expected_normalizer %{
    "type" => "BertNormalizer",
    "clean_text" => true,
    "handle_chinese_chars" => true,
    "strip_accents" => nil,
    "lowercase" => true
  }

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [snapshot: :string, out: :string, variant: :string])

    snapshot = opts[:snapshot] || Mix.raise("--snapshot <dir> is required")
    out = opts[:out] || Mix.raise("--out <dir> is required")
    variant = opts[:variant] || "256-int8"

    case build(snapshot, out, variant) do
      {:ok, path, digest} ->
        Mix.shell().info("wrote #{path}\nsha256 #{digest}")

      {:error, reason} ->
        Mix.raise("trinity.static.build: #{inspect(reason)}")
    end
  end

  @doc """
  The build, callable from a test: `{:ok, path, sha256}` or `{:error, reason}`. Refuses
  upstream files whose digest is not the pinned one, and a tokenizer that is not the pipeline
  the Elixir tokenizer implements.
  """
  @spec build(Path.t(), Path.t(), String.t()) :: {:ok, Path.t(), String.t()} | {:error, term()}
  def build(snapshot, out, variant) do
    weights = Path.join([snapshot, "0_StaticEmbedding", "model.safetensors"])
    tokenizer = Path.join([snapshot, "0_StaticEmbedding", "tokenizer.json"])
    pinned = Static.upstream_digests()

    with {:ok, spec} <- fetch_variant(variant),
         {:ok, wbin} <- File.read(weights),
         :ok <- digest(wbin, pinned.weights, :weights),
         {:ok, tbin} <- File.read(tokenizer),
         :ok <- digest(tbin, pinned.tokenizer, :tokenizer),
         {:ok, tjson} <- Jason.decode(tbin),
         {:ok, vocab} <- vocab(tjson),
         {:ok, matrix, rows, cols} <- StaticArtifact.read_safetensors(wbin),
         true <- rows == length(vocab) || {:error, {:rows, rows, length(vocab)}} do
      bytes =
        StaticArtifact.build(matrix, rows, cols, vocab,
          dim: spec.dim,
          quantization: spec.quantization,
          provenance: %{
            "model" => Static.model(),
            "revision" => Static.revision(),
            "upstream_weights_sha256" => pinned.weights,
            "upstream_tokenizer_sha256" => pinned.tokenizer
          }
        )

      File.mkdir_p!(out)
      path = Path.join(out, Static.file_name(variant))
      File.write!(path, bytes)
      {:ok, path, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    end
  end

  defp fetch_variant(variant) do
    case Map.fetch(Static.variants(), variant) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_variant, variant, Map.keys(Static.variants())}}
    end
  end

  defp digest(bin, expected, what) do
    actual = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
    if actual == expected, do: :ok, else: {:error, {:upstream_digest, what, actual}}
  end

  # The vocabulary in id order, after checking the pipeline is the one WordPiece implements.
  defp vocab(%{"normalizer" => n, "pre_tokenizer" => p, "model" => m}) do
    cond do
      n != @expected_normalizer ->
        {:error, {:normalizer, n}}

      p != %{"type" => "BertPreTokenizer"} ->
        {:error, {:pre_tokenizer, p}}

      Map.take(m, ~w(type unk_token continuing_subword_prefix max_input_chars_per_word)) !=
          %{
            "type" => "WordPiece",
            "unk_token" => "[UNK]",
            "continuing_subword_prefix" => "##",
            "max_input_chars_per_word" => 100
          } ->
        {:error, {:model, Map.delete(m, "vocab")}}

      true ->
        dense_vocab(m["vocab"])
    end
  end

  defp vocab(_), do: {:error, :not_a_tokenizer_json}

  # The tokens in id order, when the ids are exactly 0 to n - 1 (a line of the artifact's
  # vocabulary is its id, so a gap or a repeat would shift every token after it).
  defp dense_vocab(vocab) do
    sorted = Enum.sort_by(vocab, &elem(&1, 1))
    ids = Enum.map(sorted, &elem(&1, 1))

    if ids == Enum.to_list(0..(map_size(vocab) - 1)),
      do: {:ok, Enum.map(sorted, &elem(&1, 0))},
      else: {:error, :vocab_ids_not_dense}
  end
end
