# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedders.Static do
  @moduledoc """
  The static floor (slice 133): `sentence-transformers/static-retrieval-mrl-en-v1` in pure
  Elixir. A static embedding model is `EmbeddingBag(vocab, dim, mode = mean)`: look each token
  up, take the mean, normalise. No tensor runtime and no NIF, so it runs wherever the BEAM does
  (Windows, Burrito's musl, macOS, UBI9, an air-gapped host).

  The weights are a derived artifact (`Trinity.Memory.StaticArtifact`, built by
  `mix trinity.static.build` from the upstream snapshot at the pinned revision): by default 256
  dimensions, int8 with a float32 scale per token row, 7.8 MB. Its SHA-256 is pinned here and
  checked when the file is first loaded in a VM; a mismatch is `{:off, :weights_digest_mismatch}`
  and the application still boots (D3: a runtime fault turns semantic memory off with a reason,
  full-text search continues). A missing file is `{:off, :weights_missing}`.

  **No weights are in this tree** (slice 133 NOTES, D7: not before legal review of the model's
  licence and training-data terms). The file is looked for, in order: `config :trinity, :memory,
  static_dir:`, `TRINITY_STATIC_MODEL_DIR`, the application's `priv/models/static` (where a
  bundle would carry it once D7 allows), and `<data dir>/models/static`.

  Tokens come from `Trinity.Memory.WordPiece` over the artifact's vocabulary. A text with no
  tokens (only control or zero-width characters) is the zero vector, as an empty bag's mean is.
  """
  @behaviour Trinity.Memory.Embedder

  alias Trinity.Memory.{Space, StaticArtifact, WordPiece}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @model "sentence-transformers/static-retrieval-mrl-en-v1"
  @revision "f60985c706f192d45d218078e49e5a8b6f15283a"
  # SHA-256 of the upstream `0_StaticEmbedding/model.safetensors` and `tokenizer.json` at the
  # revision above (`sha256sum`, 2026-10-08); recorded in the artifact's header as provenance.
  @upstream_weights "164fc63ee9f9267be7378fcbd7df99d09788a2f45244c92aa99ae5a574925716"
  @upstream_tokenizer "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"

  # The derived artifacts `mix trinity.static.build` writes from that snapshot, by variant, and
  # their SHA-256 (`sha256` printed by the task, 2026-10-08; built twice, the same bytes). The
  # build is deterministic, so anyone holding the snapshot can rebuild and compare.
  @variants %{
    "256-int8" => %{
      dim: 256,
      quantization: :int8,
      sha256: "5990c1104963d8e2402854c80b9a8f8e3a490085c037f25ced63642f4578c520"
    },
    "1024-f32" => %{
      dim: 1024,
      quantization: :f32,
      sha256: "c8e427cc6aa3d55755d9c4085f6ab7572e95a509ff9e665f352f7d231db66299"
    }
  }

  @runtime_version "1"

  @doc "The upstream model id."
  @spec model() :: String.t()
  def model, do: @model

  @doc "The pinned upstream revision."
  @spec revision() :: String.t()
  def revision, do: @revision

  @doc "The upstream files' SHA-256, as `%{weights: _, tokenizer: _}`."
  @spec upstream_digests() :: %{weights: String.t(), tokenizer: String.t()}
  def upstream_digests, do: %{weights: @upstream_weights, tokenizer: @upstream_tokenizer}

  @doc "The variants and their pinned digests."
  @spec variants() :: %{String.t() => map()}
  def variants, do: @variants

  @doc "The configured variant: `config :trinity, :memory, static_variant:` (`\"256-int8\"`)."
  @spec variant() :: String.t()
  def variant, do: Keyword.get(memory_config(), :static_variant, "256-int8")

  @doc "The artifact's file name for a variant."
  @spec file_name(String.t()) :: String.t()
  def file_name(variant), do: "static-retrieval-mrl-en-v1-#{variant}.tsw"

  @doc "The directories searched for the artifact, in order."
  @spec search_dirs() :: [Path.t()]
  def search_dirs do
    [
      Keyword.get(memory_config(), :static_dir),
      System.get_env("TRINITY_STATIC_MODEL_DIR"),
      Application.app_dir(:trinity, "priv/models/static"),
      Path.join([Trinity.Paths.data_dir(), "models", "static"])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc "The artifact's path, the first directory that holds it, or nil."
  @spec path() :: Path.t() | nil
  def path do
    name = file_name(variant())

    Enum.find_value(search_dirs(), fn dir ->
      (p = Path.join(dir, name)) |> File.regular?() && p
    end)
  end

  @impl true
  def dim, do: Map.fetch!(@variants, variant()).dim

  @impl true
  def model_id, do: "static:" <> @model <> "@" <> variant()

  @impl true
  def space do
    v = Map.fetch!(@variants, variant())

    %Space{
      model_id: @model,
      revision: @revision,
      weights_digest: expected_digest(v.sha256),
      tokenizer_digest: @upstream_tokenizer,
      dim: v.dim,
      pooling: "mean",
      normalisation: "l2",
      quantization: Atom.to_string(v.quantization),
      query_prompt: "",
      document_prompt: "",
      max_input_tokens: "none",
      truncation: "none",
      runtime: "trinity-static",
      runtime_version: @runtime_version,
      locality: "in_process",
      num_ctx: "none"
    }
  end

  @doc """
  The static space's own thresholds (AC11), provisional until the eval re-derives them: measured
  on 2026-10-08 (slice 133 NOTES, decision 17), a decision and its negation at 0.9703, the
  closest restatement at 0.9832, unrelated pairs near 0. A bag of words cannot see order, so
  "tea over coffee" and "coffee over tea" are 1.0 and no threshold separates them.
  """
  @impl true
  def thresholds, do: %{floor: 0.3, dedupe: 0.98}

  @impl true
  def availability do
    case load() do
      {:ok, _} -> :ok
      {:error, reason} -> {:off, reason}
    end
  end

  @impl true
  def embed(texts) when is_list(texts) do
    with {:ok, loaded} <- load() do
      {:ok, Enum.map(texts, &(loaded |> pooled(&1, :mean) |> normalise()))}
    end
  end

  @doc """
  The pooled vector before normalisation (what the reference's `StaticEmbedding` returns), for
  AC10's comparison. `pooling` is `:mean`, the model's; `:sum` exists only so the parity test
  can show that a wrong pooling fails it.
  """
  @spec pooled_vector(String.t(), :mean | :sum) :: {:ok, [float()]} | {:error, term()}
  def pooled_vector(text, pooling \\ :mean) do
    with {:ok, loaded} <- load(), do: {:ok, pooled(loaded, text, pooling)}
  end

  @doc "The token ids the embedder looks up for a text."
  @spec token_ids(String.t()) :: {:ok, [non_neg_integer()]} | {:error, term()}
  def token_ids(text) do
    with {:ok, %{tokenizer: tok}} <- load(), do: {:ok, WordPiece.encode(tok, text)}
  end

  @doc "The tokenizer over the loaded artifact's vocabulary."
  @spec tokenizer() :: {:ok, WordPiece.t()} | {:error, term()}
  def tokenizer do
    with {:ok, %{tokenizer: tok}} <- load(), do: {:ok, tok}
  end

  defp pooled(%{artifact: a, tokenizer: tok}, text, pooling) do
    ids = WordPiece.encode(tok, text)
    zero = List.duplicate(0.0, a.dim)

    sum =
      Enum.reduce(ids, zero, fn id, acc ->
        Enum.zip_with(acc, StaticArtifact.row(a, id), &(&1 + &2))
      end)

    case {pooling, length(ids)} do
      {_, 0} -> zero
      {:sum, _} -> sum
      {:mean, n} -> Enum.map(sum, &(&1 / n))
    end
  end

  defp normalise(v) do
    norm = :math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2)))
    if norm == 0.0, do: v, else: Enum.map(v, &(&1 / norm))
  end

  @doc """
  Loads the configured variant once per VM: reads the file, checks its SHA-256 against the
  pinned digest, parses it and builds the tokenizer. `{:error, :weights_missing}`,
  `{:error, :weights_digest_mismatch}` or `{:error, {:weights_unreadable, reason}}`. The
  result, either way, is kept until `reload/0`.
  """
  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    key = {__MODULE__, variant(), path()}

    case :persistent_term.get(key, nil) do
      nil ->
        result = do_load(elem(key, 2), Map.fetch!(@variants, variant()))
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Forgets what `load/0` read, so the next call reads and checks the file again."
  @spec reload() :: :ok
  def reload do
    for {{__MODULE__, _, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  defp do_load(nil, _variant), do: {:error, :weights_missing}

  defp do_load(path, variant) do
    with {:ok, bin} <- read(path),
         :ok <- check_digest(bin, variant),
         {:ok, artifact} <- parse(bin) do
      {:ok, %{artifact: artifact, tokenizer: WordPiece.new(artifact.vocab), path: path}}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the path is `path/0`'s: a constant file name under
  # the configured static directory, `TRINITY_STATIC_MODEL_DIR`, the application's priv or the
  # data directory, all set by the operator; and the bytes read are checked against a pinned
  # SHA-256 before anything uses them.
  @sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, {:weights_unreadable, reason}}
    end
  end

  defp check_digest(bin, %{sha256: expected}) do
    expected = expected_digest(expected)
    actual = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
    if actual == expected, do: :ok, else: {:error, :weights_digest_mismatch}
  end

  # The pinned digest, unless configuration names another (the suite's synthetic artifacts, and
  # an operator who built a variant this tree does not pin). A configured digest is still a
  # digest: the file must match it.
  defp expected_digest(pinned) do
    case Keyword.get(memory_config(), :static_sha256) do
      nil -> pinned
      configured -> configured
    end
  end

  defp parse(bin) do
    case StaticArtifact.parse(bin) do
      {:ok, a} -> {:ok, a}
      {:error, reason} -> {:error, {:weights_unreadable, reason}}
    end
  end

  defp memory_config, do: Application.get_env(:trinity, :memory, [])
end
