# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.BPE do
  @moduledoc """
  A byte-level BPE tokenizer in pure Elixir (slice 134): how the Tier 3 client counts the tokens
  it is about to send, so that it can refuse an over-length input itself and catch a service
  that truncates silently (`Trinity.Memory.Embedders.Ollama`).

  It reproduces the pipeline of the Qwen2 family's tokenizer (`tokenizer.ggml.pre = "qwen2"` in a
  GGUF; a `ByteLevel` BPE in Hugging Face `tokenizers`):

  1. **Added tokens first**, matched in the raw text, leftmost and longest: the control and
     user-defined tokens (`<|endoftext|>`, `<think>`, ...) stand for their own ids, and the text
     between them is tokenized on its own.
  2. **NFC** each remaining piece.
  3. **Pre-tokenise** with the Qwen2 pattern (contractions, letters with one leading
     non-letter, single digits, punctuation runs, newlines, whitespace).
  4. **Byte-level**: every UTF-8 byte of a piece becomes one printable character (the GPT-2
     byte map), so no input is ever unknown.
  5. **BPE**: merge the adjacent pair of lowest rank until no pair has a rank, then look each
     symbol up.

  `count/2` adds the beginning and end tokens the model's metadata asks for (Qwen3-Embedding
  appends `<|endoftext|>`), which is what the service reports as `prompt_eval_count`.

  The vocabulary and merges are the model's, read from its verified GGUF at import and kept in a
  file of their own (`to_file/1`, `from_file/1`); none are in this tree.
  """

  @enforce_keys [:vocab, :ranks, :added, :bos, :eos]
  defstruct [:vocab, :ranks, :added, :bos, :eos]

  @type t :: %__MODULE__{
          vocab: %{String.t() => non_neg_integer()},
          ranks: %{{String.t(), String.t()} => non_neg_integer()},
          added: [{String.t(), non_neg_integer()}],
          bos: non_neg_integer() | nil,
          eos: non_neg_integer() | nil
        }

  @format "trinity-bpe-1"

  # Hugging Face's Qwen2 split pattern (the `(?i:...)` contractions, then letters with an optional
  # leading non-letter, single digits, punctuation runs with trailing newlines, newline runs,
  # whitespace not followed by a non-space, whitespace). `u` makes `\p{L}` and `\p{N}` Unicode.
  # `\s` is spelled out as Unicode's White_Space, which is what the reference's regex engine
  # means by it: PCRE's `\s` also matches U+180E (a format character since Unicode 6.3), and
  # that one character split a parity fixture differently (slice 134 NOTES, decision 14).
  @ws ~S"\t\n\x{0B}\f\r \x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}"
  @pattern "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^#{@ws}\\p{L}\\p{N}]+[\\r\\n]*|[#{@ws}]*[\\r\\n]+|[#{@ws}]+(?![^#{@ws}])|[#{@ws}]+"

  @doc """
  A tokenizer from a model's tokens (in id order), its merges (`"a b"` strings, in rank order),
  and options: `added:` the ids matched as whole tokens in the raw text, `bos:` and `eos:` the ids
  `count/2` adds (nil for none).
  """
  @spec new([String.t()], [String.t()], keyword()) :: t()
  def new(tokens, merges, opts \\ []) do
    vocab = tokens |> Enum.with_index() |> Map.new()

    ranks =
      merges
      |> Enum.with_index()
      |> Map.new(fn {m, i} ->
        [a, b] = String.split(m, " ", parts: 2)
        {{a, b}, i}
      end)

    by_id = List.to_tuple(tokens)

    added =
      opts
      |> Keyword.get(:added, [])
      |> Enum.map(&{elem(by_id, &1), &1})
      |> Enum.sort_by(fn {t, _} -> -byte_size(t) end)

    %__MODULE__{
      vocab: vocab,
      ranks: ranks,
      added: added,
      bos: Keyword.get(opts, :bos),
      eos: Keyword.get(opts, :eos)
    }
  end

  @doc """
  The tokenizer a GGUF's metadata describes (`Trinity.Memory.GGUF.metadata/1`): a `gpt2` model
  with the `qwen2` pre-tokenizer. Control (3) and user-defined (4) token types are the added
  tokens. `{:error, reason}` for any other tokenizer, which this module does not reproduce.
  """
  @spec from_gguf(map()) :: {:ok, t()} | {:error, term()}
  def from_gguf(%{} = meta) do
    with {:model, "gpt2"} <- {:model, meta["tokenizer.ggml.model"]},
         {:pre, "qwen2"} <- {:pre, meta["tokenizer.ggml.pre"]},
         tokens when is_list(tokens) <- meta["tokenizer.ggml.tokens"],
         merges when is_list(merges) <- meta["tokenizer.ggml.merges"],
         types when is_list(types) <- meta["tokenizer.ggml.token_type"] do
      added = for {t, i} <- Enum.with_index(types), t in [3, 4], do: i

      {:ok,
       new(tokens, merges,
         added: added,
         bos:
           if(meta["tokenizer.ggml.add_bos_token"] == true,
             do: meta["tokenizer.ggml.bos_token_id"]
           ),
         eos:
           if(meta["tokenizer.ggml.add_eos_token"] == true,
             do: meta["tokenizer.ggml.eos_token_id"]
           )
       )}
    else
      {:model, other} -> {:error, {:unsupported_tokenizer, other}}
      {:pre, other} -> {:error, {:unsupported_pre_tokenizer, other}}
      _ -> {:error, :tokenizer_metadata_missing}
    end
  end

  @doc """
  The token ids of a text, without the beginning and end tokens.
  """
  @spec encode(t(), String.t()) :: [non_neg_integer()]
  def encode(%__MODULE__{} = t, text) when is_binary(text) do
    t.added
    |> split_added(text)
    |> Enum.flat_map(fn
      {:added, id} -> [id]
      {:text, piece} -> encode_piece(t, piece)
    end)
  end

  @doc "How many tokens the model sees for a text: `encode/2` plus the beginning and end tokens."
  @spec count(t(), String.t()) :: non_neg_integer()
  def count(%__MODULE__{} = t, text) do
    length(encode(t, text)) + if(t.bos, do: 1, else: 0) + if(t.eos, do: 1, else: 0)
  end

  defp encode_piece(t, piece) do
    piece
    |> :unicode.characters_to_nfc_binary()
    |> pre_tokenize()
    |> Enum.flat_map(fn word -> word |> byte_symbols() |> merge(t.ranks) |> ids(t.vocab) end)
  end

  @doc "The Qwen2 pre-tokenizer's pieces of a (normalised) text."
  @spec pre_tokenize(String.t()) :: [String.t()]
  def pre_tokenize(text) do
    Regex.scan(regex(), text) |> Enum.map(&hd/1)
  end

  defp regex do
    case :persistent_term.get({__MODULE__, :regex}, nil) do
      nil ->
        r = Regex.compile!(@pattern, "u")
        :persistent_term.put({__MODULE__, :regex}, r)
        r

      r ->
        r
    end
  end

  # Leftmost, longest added token; the text around it split again.
  defp split_added([], text), do: [{:text, text}]

  defp split_added(added, text) do
    case first_added(added, text) do
      nil ->
        [{:text, text}]

      {pos, tok, id} ->
        before = binary_part(text, 0, pos)
        rest_at = pos + byte_size(tok)
        rest = binary_part(text, rest_at, byte_size(text) - rest_at)
        head = if before == "", do: [], else: [{:text, before}]
        head ++ [{:added, id} | split_added(added, rest)]
    end
  end

  defp first_added(added, text) do
    added
    |> Enum.flat_map(fn {tok, id} ->
      case :binary.match(text, tok) do
        {pos, _} -> [{pos, tok, id}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(fn {pos, tok, _} -> {pos, -byte_size(tok)} end, fn -> nil end)
  end

  ## Byte level

  @byte_map (fn ->
               printable =
                 Enum.to_list(?!..?~) ++ Enum.to_list(0xA1..0xAC) ++ Enum.to_list(0xAE..0xFF)

               {map, _} =
                 Enum.reduce(0..255, {%{}, 0}, fn b, {acc, n} ->
                   if b in printable,
                     do: {Map.put(acc, b, <<b::utf8>>), n},
                     else: {Map.put(acc, b, <<256 + n::utf8>>), n + 1}
                 end)

               map
             end).()

  @doc "The GPT-2 byte map: each byte's printable stand-in."
  @spec byte_char(byte()) :: String.t()
  def byte_char(b) when b in 0..255, do: Map.fetch!(@byte_map, b)

  defp byte_symbols(word), do: for(<<b <- word>>, do: Map.fetch!(@byte_map, b))

  ## BPE

  defp merge([_] = symbols, _ranks), do: symbols
  defp merge([], _ranks), do: []

  defp merge(symbols, ranks) do
    case best_pair(symbols, ranks) do
      nil -> symbols
      pair -> symbols |> apply_merge(pair, []) |> merge(ranks)
    end
  end

  defp best_pair(symbols, ranks) do
    symbols
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(nil, fn [a, b], best ->
      case Map.fetch(ranks, {a, b}) do
        {:ok, r} when best == nil or r < elem(best, 0) -> {r, {a, b}}
        _ -> best
      end
    end)
    |> case do
      nil -> nil
      {_, pair} -> pair
    end
  end

  defp apply_merge([a, b | rest], {a, b} = pair, acc), do: apply_merge(rest, pair, [a <> b | acc])
  defp apply_merge([x | rest], pair, acc), do: apply_merge(rest, pair, [x | acc])
  defp apply_merge([], _pair, acc), do: Enum.reverse(acc)

  # A byte-level vocabulary holds every single byte's character, so a symbol it lacks is split
  # back into those; a vocabulary missing a byte is not one this module can count, and raises.
  defp ids(symbols, vocab) do
    Enum.flat_map(symbols, fn s ->
      case Map.fetch(vocab, s) do
        {:ok, id} -> [id]
        :error -> s |> String.graphemes() |> Enum.map(&Map.fetch!(vocab, &1))
      end
    end)
  end

  ## The tokenizer file

  @doc """
  The tokenizer as a file's bytes: JSON with fixed key order (`format`, `bos`, `eos`, `added`,
  `tokens`, `merges`), so the same tokenizer is always the same bytes and its SHA-256 can be a
  space's `tokenizer_digest`.
  """
  @spec to_file(t()) :: binary()
  def to_file(%__MODULE__{} = t) do
    tokens = t.vocab |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

    merges =
      t.ranks |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(fn {{a, b}, _} -> a <> " " <> b end)

    added = t.added |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    Jason.OrderedObject.new([
      {"format", @format},
      {"bos", t.bos},
      {"eos", t.eos},
      {"added", added},
      {"tokens", tokens},
      {"merges", merges}
    ])
    |> Jason.encode!()
  end

  @doc "A tokenizer back from `to_file/1`'s bytes."
  @spec from_file(binary()) :: {:ok, t()} | {:error, term()}
  def from_file(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, %{"format" => @format, "tokens" => tokens, "merges" => merges} = m}
      when is_list(tokens) and is_list(merges) ->
        {:ok, new(tokens, merges, added: m["added"] || [], bos: m["bos"], eos: m["eos"])}

      {:ok, _} ->
        {:error, :not_a_tokenizer_file}

      {:error, _} ->
        {:error, :not_a_tokenizer_file}
    end
  end
end
