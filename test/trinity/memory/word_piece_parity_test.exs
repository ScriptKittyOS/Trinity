# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.WordPieceParityTest do
  @moduledoc """
  Slice 133, AC9: the pure-Elixir WordPiece gives the ids the reference tokenizer gives, on
  5,000 natural sentences and a 1,000-item adversarial set (accents, CJK, emoji, zero-width
  joiners, control characters, words over 100 characters, the special tokens' literals). One
  mismatched id fails it.

  The reference is Hugging Face `tokenizers` at the version `scripts/static/reference_fixtures.py`
  records, over the static model's own `tokenizer.json`, encoded without special tokens as
  sentence-transformers' `StaticEmbedding` encodes. Fixtures and vocabulary live in the model
  cache, not the tree (NOTES, D7 and decision 12), so this file is `:static_weights`.

  The last test is the red the slice names: the same comparison with accent stripping broken
  must fail, or the set could not tell a correct tokenizer from a careless one.
  """
  use ExUnit.Case, async: false

  alias Trinity.Memory.{Embedders.Static, WordPiece}
  alias Trinity.StaticWeights

  @moduletag :static_weights
  @moduletag timeout: 300_000

  setup_all do
    previous = StaticWeights.use_static!()
    on_exit(fn -> StaticWeights.restore!(previous) end)
    {:ok, tok} = Static.tokenizer()
    {:ok, tok: tok}
  end

  defp mismatches(tok, rows, opts \\ []) do
    for %{"text" => text, "ids" => expected} <- rows,
        (got = WordPiece.encode(tok, text, opts)) != expected,
        do: {text, expected, got}
  end

  defp report(mismatches) do
    mismatches
    |> Enum.take(5)
    |> Enum.map_join("\n", fn {t, e, g} ->
      "  #{inspect(t)}\n    reference #{inspect(e)}\n    elixir    #{inspect(g)}"
    end)
  end

  test "AC9: 5,000 natural sentences, every id identical", %{tok: tok} do
    rows = StaticWeights.fixtures!("tokenizer-natural.jsonl")
    assert length(rows) == 5_000
    bad = mismatches(tok, rows)
    assert bad == [], "#{length(bad)} of 5,000 differ:\n#{report(bad)}"
  end

  test "AC9: 1,000 adversarial items, every id identical", %{tok: tok} do
    rows = StaticWeights.fixtures!("tokenizer-adversarial.jsonl")
    assert length(rows) == 1_000
    bad = mismatches(tok, rows)
    assert bad == [], "#{length(bad)} of 1,000 differ:\n#{report(bad)}"

    # The set exercises what it claims to: count the categories in the inputs themselves.
    texts = Enum.map(rows, & &1["text"])
    assert Enum.any?(texts, &String.contains?(&1, "\u200D")), "no zero-width joiner"
    assert Enum.any?(texts, &(&1 =~ ~r/[\x{4E00}-\x{9FFF}]/u)), "no CJK ideograph"
    assert Enum.any?(texts, &(&1 =~ ~r/[\x{1F300}-\x{1FAFF}]/u)), "no emoji"

    assert Enum.any?(texts, &(&1 =~ ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}]/u)),
           "no control character"

    assert Enum.any?(texts, &(&1 =~ ~r/\p{Mn}/u or &1 =~ ~r/[àáâãäéèêëíóöúüñç]/u)),
           "no accent"

    assert Enum.any?(texts, fn t ->
             t |> String.split(~r/\s+/u) |> Enum.any?(&(String.length(&1) > 100))
           end),
           "no word over 100 characters"
  end

  test "AC9 red: with accent stripping broken, the adversarial set fails", %{tok: tok} do
    # Lowercase each code point and keep everything else, marks included: the BERT pipeline
    # with its NFD-and-drop-marks step left out, which is the defect the slice names.
    broken = fn text ->
      for <<cp::utf8 <- text>>, into: "" do
        if cp in [?\t, ?\n, ?\r], do: " ", else: String.downcase(<<cp::utf8>>)
      end
    end

    rows = StaticWeights.fixtures!("tokenizer-adversarial.jsonl")
    bad = mismatches(tok, rows, normalize: broken)
    IO.puts("\nAC9 red: #{length(bad)} of 1,000 adversarial items differ with accents kept")
    assert bad != []
    # And accents are what it got wrong: a mismatch on an accented word is among them.
    assert Enum.any?(bad, fn {t, _, _} -> t =~ ~r/[àáâãäéèêëíóöúüñçÀÉ]|\p{Mn}/u end)
  end
end
