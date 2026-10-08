# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.StaticWeights do
  @moduledoc """
  Where the `:static_weights` tests find the static model's artifact and the reference
  fixtures (slice 133): the directory `TRINITY_STATIC_MODEL_DIR` names, holding the artifacts
  `mix trinity.static.build` writes and a `fixtures/` directory `scripts/static/reference_fixtures.py`
  writes. None of it is in the tree (NOTES, D7).

  The tests that use this are tagged `:static_weights` and excluded when the variable is unset
  (`test/test_helper.exs`). When it is set, a missing file **fails** the test, by `flunk/1` with
  the path: never a skip, so a set variable pointing at nothing cannot pass for a tested floor.
  """
  import ExUnit.Assertions, only: [flunk: 1]

  @doc "The directory, or a failure naming the variable."
  @spec dir!() :: Path.t()
  def dir! do
    case System.get_env("TRINITY_STATIC_MODEL_DIR") do
      blank when blank in [nil, ""] ->
        flunk("TRINITY_STATIC_MODEL_DIR is unset, yet a :static_weights test ran")

      dir ->
        unless File.dir?(dir), do: flunk("TRINITY_STATIC_MODEL_DIR=#{dir} is not a directory")
        dir
    end
  end

  @doc "A file under the directory, or a failure naming what is missing."
  @spec file!(Path.t()) :: Path.t()
  def file!(relative) do
    path = Path.join(dir!(), relative)
    unless File.regular?(path), do: flunk("missing #{path} (TRINITY_STATIC_MODEL_DIR is set)")
    path
  end

  @doc "The rows of a fixture JSONL file, decoded."
  @spec fixtures!(String.t()) :: [map()]
  def fixtures!(name) do
    ("fixtures/" <> name) |> file!() |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Points the static embedder at the directory for the rest of the test (`variant`, the 256 int8
  by default) and forgets any artifact an earlier test loaded. Returns the previous memory
  configuration for `on_exit`.
  """
  @spec use_static!(String.t()) :: keyword()
  def use_static!(variant \\ "256-int8") do
    file!(Trinity.Memory.Embedders.Static.file_name(variant))
    previous = Application.get_env(:trinity, :memory, [])

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(previous, embedder: :static, static_dir: dir!(), static_variant: variant)
    )

    Trinity.Memory.Embedders.Static.reload()
    previous
  end

  @synthetic_vocab ~w([PAD] [UNK] [CLS] [SEP] [MASK] the a cat dog sat on mat is was called
                      rex lisbon coffee tea person likes moved to in . , ##s ##ing ##ed)

  @doc """
  Writes a **synthetic** artifact into `dir`: the real file format and the 256 int8 variant's
  name, over a 33-token vocabulary and seeded random weights. No model is involved, so it is in
  reach of every leg; tests that need the static path's plumbing (the store, the int8 scorer,
  the digest check) use it, and tests that need the real model use `use_static!/1`. Returns the
  file's SHA-256, which the caller configures as `static_sha256:` since no pin names it.
  """
  @spec synthetic!(Path.t()) :: String.t()
  def synthetic!(dir) do
    File.mkdir_p!(dir)
    :rand.seed(:exsss, {133, 133, 133})
    rows = length(@synthetic_vocab)

    matrix =
      for _ <- 1..(rows * 256), into: <<>>, do: <<:rand.normal()::float-little-32>>

    bytes =
      Trinity.Memory.StaticArtifact.build(matrix, rows, 256, @synthetic_vocab,
        dim: 256,
        quantization: :int8,
        provenance: %{"model" => "synthetic", "revision" => "none"}
      )

    File.write!(Path.join(dir, Trinity.Memory.Embedders.Static.file_name("256-int8")), bytes)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  @doc "Points the static embedder at a synthetic artifact in `dir`; returns the previous config."
  @spec use_synthetic!(Path.t()) :: keyword()
  def use_synthetic!(dir) do
    digest = synthetic!(dir)
    previous = Application.get_env(:trinity, :memory, [])

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(previous,
        embedder: :static,
        static_dir: dir,
        static_variant: "256-int8",
        static_sha256: digest
      )
    )

    Trinity.Memory.Embedders.Static.reload()
    previous
  end

  @doc "Restores what `use_static!/1` replaced."
  @spec restore!(keyword()) :: :ok
  def restore!(previous) do
    Application.put_env(:trinity, :memory, previous)
    Trinity.Memory.Embedders.Static.reload()
  end
end
