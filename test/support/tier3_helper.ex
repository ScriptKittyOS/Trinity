# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tier3Helper do
  @moduledoc """
  Test-only (slice 134): a small byte-level BPE vocabulary written by hand, a GGUF file carrying
  it (`gguf/1`, through a writer of the format's header), and the Ollama embedder's
  configuration pointed at a `Trinity.FakeOllama`.

  The vocabulary is every byte's GPT-2 stand-in (ids 0 to 255), five merges, and
  `<|endoftext|>` appended as the end token, so `BPE.count/2` of `"hello"` is
  `h e ll o` merged by the rules below plus one: small enough to reason about in a test.
  """
  alias Trinity.Memory.BPE

  @merges ["Ġ a", "h e", "l l", "he ll", "Ġ w"]
  @eos "<|endoftext|>"

  @doc "The tokens, in id order."
  @spec tokens() :: [String.t()]
  def tokens do
    bytes = for b <- 0..255, do: BPE.byte_char(b)
    merged = Enum.map(@merges, &String.replace(&1, " ", ""))
    bytes ++ merged ++ [@eos]
  end

  @doc "The merges, in rank order."
  @spec merges() :: [String.t()]
  def merges, do: @merges

  @doc "The end token's id."
  @spec eos() :: non_neg_integer()
  def eos, do: length(tokens()) - 1

  @doc "The tokenizer."
  @spec tokenizer() :: BPE.t()
  def tokenizer, do: BPE.new(tokens(), merges(), added: [eos()], eos: eos())

  @doc "Writes the tokenizer file into `dir`: `{path, sha256}`."
  @spec write_tokenizer!(Path.t()) :: {Path.t(), String.t()}
  def write_tokenizer!(dir) do
    bin = BPE.to_file(tokenizer())
    sha = sha256(bin)
    path = Path.join(dir, "#{sha}.bpe.json")
    File.mkdir_p!(dir)
    File.write!(path, bin)
    {path, sha}
  end

  @doc "A GGUF file's bytes with this tokenizer and a Qwen3-like header (`extra:` more pairs)."
  @spec gguf(keyword()) :: binary()
  def gguf(opts \\ []) do
    types = Enum.map(tokens(), fn t -> if t == @eos, do: 3, else: 1 end)

    pairs =
      [
        {"general.architecture", {:string, "qwen3"}},
        {"general.name", {:string, "test model"}},
        {"general.license", {:string, "apache-2.0"}},
        {"general.file_type", {:u32, 1}},
        {"qwen3.embedding_length", {:u32, Keyword.get(opts, :dim, 8)}},
        {"qwen3.context_length", {:u32, 512}},
        {"qwen3.pooling_type", {:u32, 3}},
        {"tokenizer.ggml.model", {:string, "gpt2"}},
        {"tokenizer.ggml.pre", {:string, "qwen2"}},
        {"tokenizer.ggml.tokens", {:array, :string, tokens()}},
        {"tokenizer.ggml.merges", {:array, :string, merges()}},
        {"tokenizer.ggml.token_type", {:array, :i32, types}},
        {"tokenizer.ggml.add_bos_token", {:bool, false}},
        {"tokenizer.ggml.add_eos_token", {:bool, true}},
        {"tokenizer.ggml.eos_token_id", {:u32, eos()}}
      ] ++ Keyword.get(opts, :extra, [])

    header = <<"GGUF", 3::little-32, 0::little-64, length(pairs)::little-64>>
    body = for {k, v} <- pairs, into: <<>>, do: str(k) <> value(v)
    # Stand-in tensor bytes: the reader never looks past the header.
    header <> body <> :crypto.strong_rand_bytes(Keyword.get(opts, :tail, 4096))
  end

  defp str(s), do: <<byte_size(s)::little-64, s::binary>>

  defp value({:string, s}), do: <<8::little-32>> <> str(s)
  defp value({:u32, n}), do: <<4::little-32, n::little-32>>
  defp value({:bool, b}), do: <<7::little-32, if(b, do: 1, else: 0)::8>>
  defp value({:f32, f}), do: <<6::little-32, f::little-float-32>>

  defp value({:array, type, items}) do
    code = %{string: 8, i32: 5, u32: 4}[type]

    <<9::little-32, code::little-32, length(items)::little-64>> <>
      for(i <- items, into: <<>>, do: elem_value(type, i))
  end

  defp elem_value(:string, s), do: str(s)
  defp elem_value(:i32, n), do: <<n::little-signed-32>>
  defp elem_value(:u32, n), do: <<n::little-32>>

  @doc """
  The memory configuration for an Ollama embedder at `url` (a `FakeOllama`), with the tokenizer
  file at `tokenizer`, overridden by `overrides` (keys of the `ollama:` list).
  """
  @spec memory(String.t(), {Path.t(), String.t()}, keyword()) :: keyword()
  def memory(url, {tok_path, tok_sha}, overrides \\ []) do
    ollama =
      Keyword.merge(
        [
          base_url: url,
          model: "embed-test",
          model_id: "test/embed-test",
          digest: String.duplicate("d", 64),
          weights_sha256: String.duplicate("a", 64),
          tokenizer_sha256: tok_sha,
          tokenizer_path: tok_path,
          runtime_version: "0.40.0",
          num_ctx: 64,
          max_input_tokens: 63,
          dim: 8,
          query_prompt: "Q: ",
          document_prompt: "",
          check_interval_ms: 300_000,
          timeout_ms: 5_000
        ],
        overrides
      )

    [embedder: :ollama, locality: :within_boundary, ollama: ollama]
  end

  @doc "SHA-256, lowercase hex."
  @spec sha256(iodata()) :: String.t()
  def sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
