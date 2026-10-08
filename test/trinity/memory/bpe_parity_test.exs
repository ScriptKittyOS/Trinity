# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.BPEParityTest do
  @moduledoc """
  Slice 134: the Tier 3 client counts tokens exactly as the reference does, over the model's own
  vocabulary, taken from its GGUF as the import path takes it.

  `:tier3_model`: runs where `TRINITY_TIER3_MODEL_DIR` names the directory holding
  `gguf/Qwen3-Embedding-0.6B-f16.gguf` and the fixtures `scripts/tier3/reference_fixtures.py`
  wrote into `fixtures/`; a missing file there is a failure, never a skip. Nothing here is in the
  tree: the vocabulary is the model's.
  """
  use ExUnit.Case, async: true

  alias Trinity.Memory.{BPE, GGUF}

  @moduletag :tier3_model
  @moduletag timeout: 300_000

  setup_all do
    dir = System.fetch_env!("TRINITY_TIER3_MODEL_DIR")
    gguf = Path.join([dir, "gguf", "Qwen3-Embedding-0.6B-f16.gguf"])
    assert File.regular?(gguf), "TRINITY_TIER3_MODEL_DIR is set and #{gguf} is absent"
    {:ok, meta} = GGUF.metadata(gguf)
    {:ok, tok} = BPE.from_gguf(meta)
    {:ok, tok: tok, dir: dir}
  end

  defp rows(dir, name) do
    path = Path.join([dir, "fixtures", name])
    assert File.regular?(path), "#{path} is absent"
    path |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

  defp differing(tok, rows) do
    Enum.reject(rows, fn r ->
      BPE.encode(tok, r["text"]) == r["ids"] and BPE.count(tok, r["text"]) == r["count"]
    end)
  end

  test "5,000 natural sentences: every id and every count identical", %{tok: tok, dir: dir} do
    rows = rows(dir, "tokenizer-natural.jsonl")
    assert length(rows) == 5000
    bad = differing(tok, rows)
    IO.puts("\nBPE parity: #{length(bad)} of #{length(rows)} natural sentences differ")
    assert bad == []
  end

  test "the adversarial set: every id and every count identical", %{tok: tok, dir: dir} do
    rows = rows(dir, "tokenizer-adversarial.jsonl")
    texts = Enum.map(rows, & &1["text"])
    assert Enum.any?(texts, &String.contains?(&1, "<|endoftext|>"))
    assert Enum.any?(texts, &String.contains?(&1, "\u180e"))
    bad = differing(tok, rows)
    IO.puts("\nBPE parity: #{length(bad)} of #{length(rows)} adversarial items differ")
    assert bad == [], inspect(Enum.take(bad, 3), printable_limit: 200)
  end

  test "Gate 1's 500 items: the count the client would send equals the reference's", %{
    tok: tok,
    dir: dir
  } do
    rows = rows(dir, "parity.jsonl")
    manifest = Jason.decode!(File.read!(Path.join([dir, "fixtures", "fixtures-manifest.json"])))
    prompt = manifest["query_prompt"]

    bad =
      Enum.reject(rows, fn r ->
        text = if r["role"] == "query", do: prompt <> r["text"], else: r["text"]
        BPE.count(tok, text) == r["count"]
      end)

    assert length(rows) == 500
    assert bad == []
  end
end
