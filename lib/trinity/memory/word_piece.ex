# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.WordPiece do
  @moduledoc """
  The bert-base-uncased tokenizer in pure Elixir (slice 133): what the static embedder turns a
  text into before it looks anything up. No NIF, so it runs wherever the BEAM does.

  It reproduces Hugging Face `tokenizers`' pipeline for the static model's `tokenizer.json`
  (`BertNormalizer` with clean_text, CJK handling, accent stripping and lowercasing;
  `BertPreTokenizer`; `WordPiece` with `[UNK]`, the `##` prefix and the 100-character rule),
  encoded without special tokens, as sentence-transformers' `StaticEmbedding` encodes:

  1. **Added tokens first.** The five special tokens (`[PAD]`, `[UNK]`, `[CLS]`, `[SEP]`,
     `[MASK]`) are matched in the raw text, leftmost and longest, before anything is normalised,
     and stand for their own ids; the text between them is tokenized on its own.
  2. **Normalise each character** by the table the reference itself produced
     (`Trinity.Memory.WordPiece.Tables`): removed, a space, padded as a CJK ideograph, mapped
     (NFD, non-spacing marks dropped, lowercased), or kept. Lowercasing is per character, as the
     reference's is, so a final sigma stays `σ`.
  3. **Pre-tokenise**: split on whitespace, isolate punctuation.
  4. **WordPiece** each word: greedy longest match from the left, continuations prefixed `##`,
     a word over 100 characters or with an unmatched remainder is one `[UNK]`.

  Parity with the reference is AC9's test (`test/trinity/memory/word_piece_parity_test.exs`),
  over 5,000 natural sentences and 1,000 adversarial ones, one mismatched id failing it.
  """

  import Bitwise

  alias Trinity.Memory.WordPiece.Tables

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @special ~w([PAD] [UNK] [CLS] [SEP] [MASK])
  @max_chars 100
  @prefix "##"

  @enforce_keys [:vocab, :unk_id, :added]
  defstruct [:vocab, :unk_id, :added]

  @type t :: %__MODULE__{
          vocab: %{String.t() => non_neg_integer()},
          unk_id: non_neg_integer(),
          added: [{String.t(), non_neg_integer()}]
        }

  # Sorted, disjoint `{lo, hi}` ranges as tuples, built at compile time, searched by bisection.
  @remove List.to_tuple(Tables.remove())
  @space List.to_tuple(Tables.space())
  @cjk List.to_tuple(Tables.cjk())
  @punct List.to_tuple(Tables.punct())
  @ws List.to_tuple(Tables.ws())
  @mapping Tables.mapping()

  @doc """
  A tokenizer over a vocabulary: the tokens in id order (line `n` of a `vocab.txt` is id `n`).
  The special tokens present in it are the added tokens. Raises if `[UNK]` is absent, as the
  reference refuses such a vocabulary.
  """
  @spec new([String.t()]) :: t()
  def new(tokens) when is_list(tokens) do
    vocab = tokens |> Enum.with_index() |> Map.new()

    unk_id =
      Map.get(vocab, "[UNK]") || raise ArgumentError, "a WordPiece vocabulary needs [UNK]"

    added =
      for t <- @special, id = Map.get(vocab, t), do: {t, id}

    %__MODULE__{vocab: vocab, unk_id: unk_id, added: added}
  end

  @doc "Reads a `vocab.txt` (one token per line, line order is id order)."
  # sobelow_skip reason: Traversal.FileModule: a vocabulary file named by the caller (a test, or
  # an operator building an artifact); nothing a request or a model supplies reaches it.
  @sobelow_skip ["Traversal.FileModule"]
  @spec from_vocab_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def from_vocab_file(path) do
    with {:ok, bin} <- File.read(path) do
      {:ok, bin |> String.split("\n") |> drop_trailing_empty() |> new()}
    end
  rescue
    e in ArgumentError -> {:error, {:vocab, Exception.message(e)}}
  end

  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  @doc """
  The token ids for a text, without special tokens around it. `opts[:normalize]` replaces the
  normalisation step; it exists so AC9's test can show that a broken step (accents kept) fails
  the parity set, and nothing in `lib/` passes it.
  """
  @spec encode(t(), String.t(), keyword()) :: [non_neg_integer()]
  def encode(%__MODULE__{} = tok, text, opts \\ []) when is_binary(text) do
    normalize = Keyword.get(opts, :normalize, &normalize/1)

    text
    |> split_added(tok.added)
    |> Enum.flat_map(fn
      {:added, id} ->
        [id]

      {:text, segment} ->
        segment |> normalize.() |> pre_tokenize() |> Enum.flat_map(&word(tok, &1))
    end)
  end

  @doc "The token strings for a text (the ids looked back up), for tests and inspection."
  @spec tokens(t(), String.t()) :: [String.t()]
  def tokens(%__MODULE__{vocab: vocab} = tok, text) do
    by_id = Map.new(vocab, fn {k, v} -> {v, k} end)
    tok |> encode(text) |> Enum.map(&Map.fetch!(by_id, &1))
  end

  ## Added tokens: leftmost, longest, on the raw text

  defp split_added(text, []), do: [{:text, text}]
  defp split_added(text, added), do: split_added(text, added, 0, 0, [])

  defp split_added(text, _added, from, at, acc) when at >= byte_size(text) do
    Enum.reverse(push_text(acc, text, from, byte_size(text) - from))
  end

  defp split_added(text, added, from, at, acc) do
    rest = binary_part(text, at, byte_size(text) - at)

    case longest_added(rest, added) do
      {literal, id} ->
        acc = acc |> push_text(text, from, at - from) |> then(&[{:added, id} | &1])
        next = at + byte_size(literal)
        split_added(text, added, next, next, acc)

      nil ->
        split_added(text, added, from, at + 1, acc)
    end
  end

  defp longest_added(rest, added) do
    added
    |> Enum.filter(fn {literal, _} -> String.starts_with?(rest, literal) end)
    |> Enum.max_by(fn {literal, _} -> byte_size(literal) end, fn -> nil end)
  end

  defp push_text(acc, _text, _from, 0), do: acc
  defp push_text(acc, text, from, len), do: [{:text, binary_part(text, from, len)} | acc]

  ## Normalisation, one code point at a time, by the reference's own table

  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    for <<cp::utf8 <- text>>, into: "", do: char(cp)
  end

  defp char(cp) do
    cond do
      in?(cp, @remove) -> ""
      in?(cp, @space) -> " "
      in?(cp, @cjk) -> <<?\s, cp::utf8, ?\s>>
      cp >= 0xAC00 and cp <= 0xD7A3 -> hangul(cp)
      true -> Map.get(@mapping, cp) || <<cp::utf8>>
    end
  end

  # The algorithmic decomposition of a Hangul syllable (Unicode chapter 3.12); the generator
  # checked the reference produces exactly this for every syllable.
  defp hangul(cp) do
    s = cp - 0xAC00
    l = 0x1100 + div(s, 588)
    v = 0x1161 + div(rem(s, 588), 28)
    t = 0x11A7 + rem(s, 28)
    if t == 0x11A7, do: <<l::utf8, v::utf8>>, else: <<l::utf8, v::utf8, t::utf8>>
  end

  defp in?(cp, ranges), do: bsearch(ranges, cp, 0, tuple_size(ranges) - 1)

  defp bsearch(_t, _cp, lo, hi) when lo > hi, do: false

  defp bsearch(t, cp, lo, hi) do
    mid = (lo + hi) >>> 1
    {a, b} = elem(t, mid)

    cond do
      cp < a -> bsearch(t, cp, lo, mid - 1)
      cp > b -> bsearch(t, cp, mid + 1, hi)
      true -> true
    end
  end

  ## Pre-tokenisation: whitespace splits and is dropped, punctuation is its own piece

  @doc false
  @spec pre_tokenize(String.t()) :: [String.t()]
  def pre_tokenize(text) do
    {words, current} =
      for <<cp::utf8 <- text>>, reduce: {[], []} do
        {words, current} ->
          cond do
            in?(cp, @ws) -> {flush(words, current), []}
            in?(cp, @punct) -> {[<<cp::utf8>> | flush(words, current)], []}
            true -> {words, [cp | current]}
          end
      end

    words |> flush(current) |> Enum.reverse()
  end

  defp flush(words, []), do: words
  defp flush(words, current), do: [current |> Enum.reverse() |> List.to_string() | words]

  ## WordPiece

  defp word(%__MODULE__{unk_id: unk} = tok, word) do
    chars = String.codepoints(word)

    if length(chars) > @max_chars do
      [unk]
    else
      case pieces(tok.vocab, chars, true, []) do
        :bad -> [unk]
        ids -> ids
      end
    end
  end

  # Greedy longest match from the left: the longest prefix of what is left that is in the
  # vocabulary (prefixed `##` after the first piece), then the rest; any remainder with no
  # prefix in the vocabulary makes the whole word one [UNK].
  defp pieces(_vocab, [], _first?, acc), do: Enum.reverse(acc)

  defp pieces(vocab, chars, first?, acc) do
    case longest(vocab, chars, length(chars), first?) do
      nil -> :bad
      {id, taken} -> pieces(vocab, Enum.drop(chars, taken), false, [id | acc])
    end
  end

  defp longest(_vocab, _chars, 0, _first?), do: nil

  defp longest(vocab, chars, n, first?) do
    candidate = chars |> Enum.take(n) |> Enum.join()
    candidate = if first?, do: candidate, else: @prefix <> candidate

    case Map.fetch(vocab, candidate) do
      {:ok, id} -> {id, n}
      :error -> longest(vocab, chars, n - 1, first?)
    end
  end
end
