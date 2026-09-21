# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedder do
  @moduledoc """
  Text to vectors (slice 032). One implementation is in force, chosen by
  `config :trinity, :memory, embedder:`: `:local` (`Embedders.Bumblebee`, the default:
  all-MiniLM-L6-v2 through Bumblebee and EXLA, on this machine), `:hosted`
  (`Embedders.Hosted`, a configured alternative only: it sends text to a provider and is
  never chosen for the operator), `:fake` (the suite). Every vector records the embedder's
  `model_id/0` and `dim/0` on its row, and a store never mixes models (NOTES decision 4).
  """

  @type vector :: [float()]

  @doc "The vectors for texts, in order; `{:error, reason}` when the embedder cannot run."
  @callback embed([String.t()]) :: {:ok, [vector()]} | {:error, term()}

  @doc "The dimension of this embedder's vectors."
  @callback dim() :: pos_integer()

  @doc "The model's identifier as rows record it, e.g. `\"bumblebee:sentence-transformers/all-MiniLM-L6-v2\"`."
  @callback model_id() :: String.t()

  @doc "`:ok`, or the reason this embedder cannot serve here (no model, no backend on this OS, not configured)."
  @callback availability() :: :ok | {:off, term()}

  @doc "The configured choice: `:local` unless configuration says otherwise."
  @spec configured() :: :local | :hosted | :fake
  def configured, do: Application.get_env(:trinity, :memory, []) |> Keyword.get(:embedder, :local)

  @doc "The implementation the configuration names."
  @spec impl() :: module()
  def impl do
    case configured() do
      :local -> Trinity.Memory.Embedders.Bumblebee
      :hosted -> Trinity.Memory.Embedders.Hosted
      :fake -> Trinity.Memory.Embedders.Fake
    end
  end

  @doc "Embeds through the implementation in force."
  @spec embed([String.t()]) :: {:ok, [vector()]} | {:error, term()}
  def embed(texts) when is_list(texts), do: impl().embed(texts)

  @doc "Cosine similarity of two vectors of the same length (both L2-normalised: their dot)."
  @spec cosine(vector(), vector()) :: float()
  def cosine(a, b) when length(a) == length(b) do
    {dot, na, nb} =
      Enum.zip_reduce(a, b, {0.0, 0.0, 0.0}, fn x, y, {d, p, q} ->
        {d + x * y, p + x * x, q + y * y}
      end)

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (:math.sqrt(na) * :math.sqrt(nb))
  end

  @doc "A vector as the row stores it: float32, little-endian."
  @spec to_binary(vector()) :: binary()
  def to_binary(vector), do: for(f <- vector, into: <<>>, do: <<f::float-little-32>>)

  @doc "A stored vector back to floats."
  @spec from_binary(binary()) :: vector()
  def from_binary(bin), do: for(<<f::float-little-32 <- bin>>, do: f)
end
