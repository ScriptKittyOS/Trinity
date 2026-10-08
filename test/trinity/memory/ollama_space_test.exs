# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.OllamaSpaceTest do
  @moduledoc """
  Slice 134, AC3: `num_ctx`, the query and document prompt templates and the runtime version
  are in the Tier 3 embedder's space identity, so changing any of them is a new space (133's
  property, `test/property/space_identity_test.exs`, extended to this embedder).

  The population is the embedder's configuration keys that `space/0` reads, enumerated from
  `Trinity.Memory.Embedders.Ollama`'s schema minus the ones that do not describe the vectors
  (where the service is, how long to wait, how often to check, where the tokenizer file sits,
  the thresholds), so a key added later is in the test without editing it.
  """
  use ExUnit.Case, async: false

  alias Trinity.Memory.Embedders.Ollama
  alias Trinity.Memory.Space

  # The keys that say where and how the service is reached, not what a vector means.
  @not_identity [:base_url, :model, :tokenizer_path, :check_interval_ms, :timeout_ms, :thresholds]

  @base [
    base_url: "http://embed.internal:11434",
    model: "embed-test",
    model_id: "Qwen/Qwen3-Embedding-0.6B-GGUF",
    digest: String.duplicate("d", 64),
    weights_sha256: String.duplicate("a", 64),
    tokenizer_sha256: String.duplicate("c", 64),
    runtime_version: "0.40.0",
    num_ctx: 8192,
    max_input_tokens: 8191,
    dim: 1024,
    pooling: "last",
    normalisation: "l2",
    query_prompt:
      "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:",
    document_prompt: ""
  ]

  @changed %{
    model_id: "Qwen/Qwen3-Embedding-4B-GGUF",
    digest: String.duplicate("e", 64),
    weights_sha256: String.duplicate("b", 64),
    tokenizer_sha256: String.duplicate("f", 64),
    runtime_version: "0.40.1",
    num_ctx: 8193,
    max_input_tokens: 8190,
    dim: 768,
    pooling: "mean",
    normalisation: "none",
    query_prompt: "Query: ",
    document_prompt: "Document: "
  }

  setup do
    memory = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, memory) end)
    :ok
  end

  defp space_with(ollama, locality \\ :within_boundary) do
    Application.put_env(:trinity, :memory, embedder: :ollama, locality: locality, ollama: ollama)
    Ollama.space()
  end

  defp identity_keys do
    Ollama.options_doc()
    |> then(&Regex.scan(~r/^\s*\* `:([a-z0-9_]+)`/m, &1))
    |> Enum.map(fn [_, k] -> String.to_existing_atom(k) end)
    |> Kernel.--(@not_identity)
  end

  test "the population: every identity key has a changed value in this test" do
    keys = identity_keys()

    assert :num_ctx in keys and :query_prompt in keys and :document_prompt in keys and
             :runtime_version in keys

    assert Enum.sort(keys) == Enum.sort(Map.keys(@changed))
  end

  test "AC3: changing any one identity key changes the space ID" do
    base = Space.id(space_with(@base))

    unchanged =
      for key <- identity_keys(),
          Space.id(space_with(Keyword.put(@base, key, Map.fetch!(@changed, key)))) == base,
          do: key

    assert unchanged == [], "the space ID did not change when #{inspect(unchanged)} changed"

    IO.puts(
      "\nAC3: #{length(identity_keys())} identity keys, each a new space: #{inspect(identity_keys())}"
    )
  end

  test "AC3: num_ctx, both prompt templates and the runtime version each have their own field" do
    s = space_with(@base)
    assert s.num_ctx == 8192
    assert s.query_prompt == @base[:query_prompt]
    assert s.document_prompt == ""
    assert s.runtime == "ollama" and s.runtime_version == "0.40.0"
    assert s.revision == @base[:digest]
    assert s.weights_digest == @base[:weights_sha256]
    assert s.tokenizer_digest == @base[:tokenizer_sha256]
    assert s.max_input_tokens == 8191 and s.truncation == "refuse"
  end

  test "the declared locality is part of the space" do
    refute Space.id(space_with(@base, :within_boundary)) == Space.id(space_with(@base, :external))
  end

  test "the keys that do not describe a vector leave the space alone" do
    base = Space.id(space_with(@base))

    for {key, value} <- [
          base_url: "http://other:11434",
          model: "renamed",
          check_interval_ms: 1,
          timeout_ms: 1
        ] do
      assert Space.id(space_with(Keyword.put(@base, key, value))) == base,
             "#{key} moved the space"
    end
  end
end
