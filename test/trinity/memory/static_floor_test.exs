# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.StaticFloorTest do
  @moduledoc """
  Slice 133: the static floor's plumbing on every leg, over a synthetic artifact (the real file
  format, a 33-token vocabulary, seeded random weights; `Trinity.StaticWeights.synthetic!/1`).
  The real model's parity is AC9 and AC10, under `:static_weights`.

  What is held here: the artifact's format and its refusals; the embedder's availability
  (missing, digest mismatch, unreadable); the stored int8 vector and the pure-Elixir scorer
  against the float cosine; and the whole path, a memory written and recalled through the
  static space with the int8 store.
  """
  use Trinity.DataCase, async: false

  alias Trinity.{Factory, StaticWeights}
  alias Trinity.Memory.{AlwaysOn, Embedder, Embedders.Static, Scorer, Semantic, Space, Spaces}
  alias Trinity.Memory.StaticArtifact

  setup do
    dir = Path.join(System.tmp_dir!(), "static-#{System.unique_integer([:positive])}")
    previous = StaticWeights.use_synthetic!(dir)

    on_exit(fn ->
      StaticWeights.restore!(previous)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  describe "the artifact" do
    test "round-trips: header, vocabulary, per-row int8 with float32 scales, and f32" do
      matrix =
        for x <- [1.0, -2.0, 0.5, 0.0, 0.0, 0.0, 3.0, 1.5], into: <<>>, do: <<x::float-little-32>>

      bin =
        StaticArtifact.build(matrix, 2, 4, ["[UNK]", "a"],
          dim: 2,
          quantization: :int8,
          provenance: %{"model" => "m"}
        )

      assert {:ok, a} = StaticArtifact.parse(bin)
      assert {a.rows, a.dim, a.quantization, a.vocab} == {2, 2, :int8, ["[UNK]", "a"]}
      assert a.header["model"] == "m" and a.header["source_dim"] == 4
      # Row 0 is [1.0, -2.0] truncated from four columns; its scale is 2/127.
      [x, y] = StaticArtifact.row(a, 0)
      assert_in_delta x, 1.0, 2 / 127
      assert_in_delta y, -2.0, 1.0e-6
      # A zero row stays zero.
      assert StaticArtifact.row(a, 1) == [0.0, 0.0]

      {:ok, f} =
        StaticArtifact.parse(
          StaticArtifact.build(matrix, 2, 4, ["[UNK]", "a"], dim: 4, quantization: :f32)
        )

      assert StaticArtifact.row(f, 1) == [0.0, 0.0, 3.0, 1.5]
    end

    test "refuses what is not a whole artifact, and inputs that do not agree" do
      assert {:error, :not_an_artifact} = StaticArtifact.parse("nope")
      matrix = :binary.copy(<<0::32>>, 8)
      good = StaticArtifact.build(matrix, 2, 4, ["[UNK]", "a"], dim: 4, quantization: :int8)

      assert {:error, :truncated} =
               StaticArtifact.parse(binary_part(good, 0, byte_size(good) - 1))

      assert_raise ArgumentError, fn ->
        StaticArtifact.build(matrix, 2, 4, ["[UNK]"], dim: 4, quantization: :int8)
      end

      assert {:error, :not_safetensors} = StaticArtifact.read_safetensors("x")
    end

    test "reads a single-tensor safetensors file" do
      header =
        Jason.encode!(%{"w" => %{"dtype" => "F32", "shape" => [2, 2], "data_offsets" => [0, 16]}})

      data = for x <- [1.0, 2.0, 3.0, 4.0], into: <<>>, do: <<x::float-little-32>>
      file = <<byte_size(header)::64-little>> <> header <> data
      assert {:ok, ^data, 2, 2} = StaticArtifact.read_safetensors(file)
    end
  end

  describe "the embedder's availability" do
    test "on with a matching digest; the space names the configured digest" do
      assert Static.availability() == :ok
      digest = Application.get_env(:trinity, :memory)[:static_sha256]
      assert Static.space().weights_digest == digest
      assert Static.space().quantization == "int8"
      assert Static.space().locality == "in_process"
    end

    test "a missing file is :weights_missing, a changed byte :weights_digest_mismatch", %{
      dir: dir
    } do
      file = Path.join(dir, Static.file_name("256-int8"))
      bin = File.read!(file)
      File.write!(file, <<bin::binary-size(byte_size(bin) - 1), 0>>)
      Static.reload()
      assert Static.availability() == {:off, :weights_digest_mismatch}
      assert {:error, :weights_digest_mismatch} = Static.embed(["the cat"])

      # Missing everywhere it is looked for: the real artifact's directory, where a run with the
      # weights names one, would otherwise be found next.
      env = System.get_env("TRINITY_STATIC_MODEL_DIR")
      System.delete_env("TRINITY_STATIC_MODEL_DIR")
      on_exit(fn -> if env, do: System.put_env("TRINITY_STATIC_MODEL_DIR", env) end)
      File.rm!(file)
      Static.reload()
      assert Static.availability() == {:off, :weights_missing}
    end

    test "the pinned digests are the real artifacts', and the space without configuration uses them" do
      memory = Application.get_env(:trinity, :memory)
      Application.put_env(:trinity, :memory, Keyword.delete(memory, :static_sha256))

      assert Static.space().weights_digest ==
               "5990c1104963d8e2402854c80b9a8f8e3a490085c037f25ced63642f4578c520"

      # The synthetic file is not the pinned one, so the pinned digest refuses it.
      Static.reload()
      assert Static.availability() == {:off, :weights_digest_mismatch}
    end
  end

  describe "the int8 scorer" do
    test "the int8 cosine tracks the float cosine, and the store's order is the float order" do
      :rand.seed(:exsss, {1, 2, 3})
      vs = for _ <- 1..200, do: for(_ <- 1..256, do: :rand.normal())
      q = for _ <- 1..256, do: :rand.normal()
      q8 = Scorer.quantize(q)
      index = Scorer.prepare(Enum.with_index(vs, fn v, i -> {i, Scorer.quantize(v)} end))

      exact = Scorer.exact(index, q8, 10)
      float = vs |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, Embedder.cosine(q, v)} end)

      for {id, score} <- exact do
        {_, f} = List.keyfind(float, id, 0)
        assert_in_delta score, f, 0.02
      end

      # The prefilter with every row as a candidate is the exact search.
      assert Scorer.prefilter(index, q8, 10, 200) == exact
      assert Scorer.hamming(Scorer.signs(q8), Scorer.signs(q8)) == 0
      assert Scorer.quantize([0.0, 0.0]) == <<0, 0>>
      assert Scorer.cosine(<<0, 0>>, 0, <<1, 1>>, 2) == 0.0
    end

    test "the stored vector of an int8 space is 256 signed bytes, a float32 space's 4 bytes a component" do
      v = for i <- 1..256, do: :math.sin(i)
      assert byte_size(Space.encode_vector("int8", v)) == 256
      assert byte_size(Space.encode_vector("f32", v)) == 1024
      assert Space.vector_bytes("int8", 256) == 256
      back = Space.decode_vector("int8", Space.encode_vector("int8", v))
      assert Embedder.cosine(back, v) > 0.9999
    end
  end

  describe "the whole path through the static space" do
    test "a memory written and recalled: pinned to the static space, stored int8, ranked by the scorer" do
      persona = Factory.persona!()
      scope = AlwaysOn.persona_scope(persona.id)

      for {k, body} <- [{"rex", "the dog is called rex"}, {"tea", "the person likes tea"}] do
        {:ok, _} =
          Semantic.add(%{persona_id: persona.id, scope: scope, key: k, body: body}, by: "test")
      end

      row = Spaces.active()
      assert row.id == Space.id(Static.space())
      assert row.quantization == "int8" and row.dim == 256

      assert {:ok, [first | _]} = Semantic.search(persona.id, [scope], "dog called rex", 2)
      assert first.entry.key == "rex"
      assert first.space_id == row.id
      assert Semantic.thresholds() == %{floor: 0.3, dedupe: 0.98}
    end
  end
end
