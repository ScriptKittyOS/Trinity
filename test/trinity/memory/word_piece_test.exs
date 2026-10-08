# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.WordPieceTest do
  @moduledoc """
  Slice 133: the pure-Elixir WordPiece's rules on a hand-written vocabulary, so they run on every
  leg (AC9's parity against the reference needs the model's vocabulary, which is not in the tree,
  and is `test/trinity/memory/word_piece_parity_test.exs`). Each expectation below is what the
  reference does: each was checked against `tokenizers` 0.23.2 over the same vocabulary and the
  same pipeline (slice 133 NOTES).
  """
  use ExUnit.Case, async: true

  alias Trinity.Memory.WordPiece

  @vocab ~w([PAD] [UNK] [CLS] [SEP] [MASK] the cat sat un ##aff ##able ##s cafe resume , . !
            hello world 野 口 i a ##b x ##x)

  setup_all do
    {:ok, tok: WordPiece.new(@vocab)}
  end

  defp t(tok, text), do: WordPiece.tokens(tok, text)

  test "lowercases, strips accents, splits punctuation, matches longest pieces", %{tok: tok} do
    assert t(tok, "The CAT sat.") == ~w(the cat sat .)
    assert t(tok, "Café, résumé!") == ~w(cafe , resume !)
    # NFD and the marks dropped, whether the accent is precomposed or combining.
    assert t(tok, "cafe\u0301") == ~w(cafe)
    assert t(tok, "unaffable cats") == ~w(un ##aff ##able cat ##s)
  end

  test "an unmatched remainder makes the whole word one [UNK]; so does a word over 100 characters",
       %{tok: tok} do
    assert t(tok, "unaffz") == ~w([UNK])
    assert t(tok, "zebra cat") == ~w([UNK] cat)
    assert t(tok, String.duplicate("x", 100)) == ["x" | List.duplicate("##x", 99)]
    assert t(tok, String.duplicate("x", 101)) == ~w([UNK])
  end

  test "control characters go, whitespace of every kind splits, CJK ideographs stand alone",
       %{tok: tok} do
    # The controls go before splitting, so the two words become one ("helloworld": no "##world").
    assert t(tok, "hello\u0000\u200Bworld") == ~w([UNK])
    assert t(tok, "hello\u00A0world\u3000cat") == ~w(hello world cat)
    assert t(tok, "野口cat") == ~w(野 口 cat)
    assert WordPiece.normalize("a\tb\r\nc") == "a b  c"
  end

  test "special tokens are matched in the raw text before normalisation, leftmost and longest",
       %{tok: tok} do
    assert t(tok, "[CLS]the cat[SEP]") == ~w([CLS] the cat [SEP])
    # The text after a special token is a word of its own: "b", not a continuation "##b".
    assert t(tok, "a[MASK]b") == ~w(a [MASK] [UNK])
    # Lowercase is not the special token: it is normalised and split as punctuation.
    assert t(tok, "[cls]") == ~w([UNK] [UNK] [UNK])
  end

  test "lowercasing is per character, so a final sigma stays sigma (the reference's rule)" do
    assert WordPiece.normalize("ΣΟΦΟΣ") == "σοφοσ"
    assert WordPiece.normalize("İ") == "i"
    assert WordPiece.normalize("한") == "한"
  end

  test "a vocabulary without [UNK] is refused; a vocab file is read in line order" do
    assert_raise ArgumentError, fn -> WordPiece.new(~w(a b)) end
    path = Path.join(System.tmp_dir!(), "vocab-#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.join(@vocab, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    assert {:ok, tok} = WordPiece.from_vocab_file(path)
    assert WordPiece.encode(tok, "the cat") == [5, 6]
    assert {:error, :enoent} = WordPiece.from_vocab_file(path <> ".missing")
  end
end
