# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.BPETest do
  @moduledoc """
  Slice 134: the byte-level BPE's rules on a hand-written vocabulary (`Trinity.Tier3Helper`),
  on every leg, and the GGUF header reader on a file the test writes. Parity with the reference
  over the real vocabulary is `bpe_parity_test.exs` (`:tier3_model`).
  """
  use ExUnit.Case, async: true

  alias Trinity.Memory.{BPE, GGUF}
  alias Trinity.Tier3Helper

  defp tok, do: Tier3Helper.tokenizer()
  defp id(token), do: Enum.find_index(Tier3Helper.tokens(), &(&1 == token))
  defp b(char), do: id(BPE.byte_char(char))

  test "merges apply by rank: hello is hell + o" do
    assert BPE.encode(tok(), "hello") == [id("hell"), b(?o)]
    assert BPE.count(tok(), "hello") == 3
  end

  test "a leading space is the byte map's Ġ, and a space-a merges" do
    assert BPE.encode(tok(), " a") == [id("Ġa")]
    assert BPE.encode(tok(), "a a") == [b(?a), id("Ġa")]
  end

  test "every byte of any input has a symbol: nothing is unknown" do
    text = "naïve 日本 👩\u200d👩\u200d👧 \u0000"
    ids = BPE.encode(tok(), text)
    assert length(ids) == byte_size(:unicode.characters_to_nfc_binary(text))
  end

  test "an added token in the raw text is one id; the text around it is tokenized alone" do
    eos = Tier3Helper.eos()
    assert BPE.encode(tok(), "he<|endoftext|>he") == [id("he"), eos, id("he")]
    assert BPE.encode(tok(), "<|endoftext|>") == [eos]
  end

  test "the end token is counted once per text" do
    assert BPE.count(tok(), "") == 1
    assert BPE.count(tok(), "hello") == length(BPE.encode(tok(), "hello")) + 1
  end

  test "the pre-tokenizer is Qwen2's: contractions, letters, single digits, punctuation, spaces" do
    assert BPE.pre_tokenize("I'M here, 2026!\n\n  ok") ==
             ["I", "'M", " here", ",", " ", "2", "0", "2", "6", "!\n\n", " ", " ok"]
  end

  test "whitespace is Unicode's White_Space: U+180E is not a space, U+2009 is" do
    # PCRE's \s matches U+180E; the reference's engine does not (slice 134 NOTES, decision 14).
    assert BPE.pre_tokenize("U\u180e.S") == ["U", "\u180e.", "S"]
    assert BPE.pre_tokenize("a\u2009b") == ["a", "\u2009b"]
  end

  test "NFC before splitting: a decomposed é is the composed one's bytes" do
    assert BPE.encode(tok(), "e\u0301") == BPE.encode(tok(), "\u00e9")
  end

  test "the file is deterministic and reads back to the same tokenizer" do
    bin = BPE.to_file(tok())
    assert bin == BPE.to_file(tok())
    assert {:ok, back} = BPE.from_file(bin)
    assert back == tok()
    assert BPE.from_file("{}") == {:error, :not_a_tokenizer_file}
    assert BPE.from_file("not json") == {:error, :not_a_tokenizer_file}
  end

  describe "GGUF" do
    test "the header's metadata, and the tokenizer it describes" do
      bin = Tier3Helper.gguf(dim: 16)
      assert {:ok, meta} = GGUF.parse(bin)
      assert meta["general.architecture"] == "qwen3"
      assert meta["qwen3.embedding_length"] == 16
      assert meta["tokenizer.ggml.add_eos_token"] == true
      assert meta["tokenizer.ggml.tokens"] == Tier3Helper.tokens()
      assert {:ok, from_gguf} = BPE.from_gguf(meta)
      assert BPE.to_file(from_gguf) == BPE.to_file(tok())
    end

    @tag :tmp_dir
    test "a file is read in growing pieces, only as far as the header", %{tmp_dir: dir} do
      path = Path.join(dir, "m.gguf")
      File.write!(path, Tier3Helper.gguf(tail: 3_000_000))
      assert {:ok, %{"general.name" => "test model"}} = GGUF.metadata(path)
    end

    test "every scalar type and an array of each" do
      pairs = [
        {"u8", <<0::little-32, 200>>},
        {"i8", <<1::little-32, -3::signed-8>>},
        {"u16", <<2::little-32, 60_000::little-16>>},
        {"i16", <<3::little-32, -300::little-signed-16>>},
        {"u32", <<4::little-32, 4_000_000_000::little-32>>},
        {"i32", <<5::little-32, -70_000::little-signed-32>>},
        {"f32", <<6::little-32, 1.5::little-float-32>>},
        {"bool", <<7::little-32, 0>>},
        {"u64", <<10::little-32, 2 ** 40::little-64>>},
        {"i64", <<11::little-32, -(2 ** 40)::little-signed-64>>},
        {"f64", <<12::little-32, 0.25::little-float-64>>},
        {"ints",
         <<9::little-32, 5::little-32, 2::little-64, 7::little-signed-32, -7::little-signed-32>>}
      ]

      body =
        for {k, v} <- pairs, into: <<>>, do: <<byte_size(k)::little-64, k::binary, v::binary>>

      bin = <<"GGUF", 2::little-32, 0::little-64, length(pairs)::little-64, body::binary>>

      assert {:ok, meta} = GGUF.parse(bin)

      assert meta == %{
               "u8" => 200,
               "i8" => -3,
               "u16" => 60_000,
               "i16" => -300,
               "u32" => 4_000_000_000,
               "i32" => -70_000,
               "f32" => 1.5,
               "bool" => false,
               "u64" => 2 ** 40,
               "i64" => -(2 ** 40),
               "f64" => 0.25,
               "ints" => [7, -7]
             }

      nested =
        <<"GGUF", 3::little-32, 0::64, 1::little-64, 1::little-64, "n", 9::little-32,
          9::little-32, 1::little-64>>

      assert GGUF.parse(nested) == {:error, :nested_array}
      assert GGUF.parse(binary_part(bin, 0, byte_size(bin) - 3)) == {:error, :truncated}
    end

    @tag :tmp_dir
    test "a missing or empty file is refused", %{tmp_dir: dir} do
      assert GGUF.metadata(Path.join(dir, "absent.gguf")) == {:error, {:unreadable, :enoent}}
      File.write!(Path.join(dir, "empty.gguf"), "")
      assert GGUF.metadata(Path.join(dir, "empty.gguf")) == {:error, :empty}
    end

    test "refusals: not a GGUF, cut short, an unknown type, another version" do
      bin = Tier3Helper.gguf()
      assert GGUF.parse("GGML" <> binary_part(bin, 4, 100)) == {:error, :not_gguf}
      assert GGUF.parse(binary_part(bin, 0, 200)) == {:error, :truncated}

      assert GGUF.parse(<<"GGUF", 1::little-32, 0::64, 0::64>>) ==
               {:error, {:unsupported_version, 1}}

      bad = <<"GGUF", 3::little-32, 0::little-64, 1::little-64, 1::little-64, "k", 99::little-32>>
      assert GGUF.parse(bad) == {:error, {:unknown_type, 99}}
    end

    test "a tokenizer this module does not reproduce is refused" do
      {:ok, meta} = GGUF.parse(Tier3Helper.gguf())

      assert BPE.from_gguf(%{meta | "tokenizer.ggml.pre" => "llama3"}) ==
               {:error, {:unsupported_pre_tokenizer, "llama3"}}

      assert BPE.from_gguf(%{meta | "tokenizer.ggml.model" => "llama"}) ==
               {:error, {:unsupported_tokenizer, "llama"}}

      assert BPE.from_gguf(Map.delete(meta, "tokenizer.ggml.merges")) ==
               {:error, :tokenizer_metadata_missing}
    end
  end
end
