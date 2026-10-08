# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.FakeEmbedderB do
  @moduledoc """
  A second fake embedder for the suite (slice 133): 256 wide, its own seed, so its own space.
  `Trinity.Memory.Embedders.Fake` takes its width from configuration and so can be only one
  space at a time; a re-tier needs two configured at once (`embedder: [Trinity.FakeEmbedderB,
  :fake]`), and AC2 needs a 256-wide space beside the 384-wide one on Postgres.
  """
  @behaviour Trinity.Memory.Embedder

  alias Trinity.Memory.Embedders.Fake
  alias Trinity.Memory.Space

  @dim 256

  @impl true
  def dim, do: @dim

  @impl true
  def model_id, do: "fake:sha256-256-b"

  @impl true
  def availability, do: :ok

  @impl true
  def space,
    do: %{Space.legacy(model_id(), @dim) | locality: "in_process", runtime: "trinity-fake"}

  @impl true
  def thresholds, do: %{floor: 0.3, dedupe: 0.92}

  @impl true
  def embed(texts), do: {:ok, Enum.map(texts, &vector/1)}

  @doc "The vector for one text."
  @spec vector(String.t()) :: [float()]
  def vector(text), do: Fake.vector(text, @dim, "b")
end
