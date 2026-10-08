# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedder do
  @moduledoc """
  Text to vectors (slice 032). One implementation is in force, chosen by
  `config :trinity, :memory, embedder:`: `:local` (`Embedders.Bumblebee`, the default:
  all-MiniLM-L6-v2 through Bumblebee and EXLA, on this machine), `:static`
  (`Embedders.Static`, slice 133: the pure-Elixir floor), `:hosted` (`Embedders.Hosted`, a
  configured alternative only: it sends text to a provider and is never chosen for the
  operator), `:fake` (the suite), or a module implementing this behaviour.

  Slice 133: every embedder names the embedding space it writes (`space/0`, a
  `Trinity.Memory.Space`), and every stored vector carries that space's ID. A store answers
  from exactly one space, pinned by the operator (`Trinity.Memory.Spaces`); an embedder whose
  space is not the pinned one does not serve that store, and nothing switches spaces
  implicitly. Thresholds are the space's own (`thresholds/0`): a cosine that means "the same
  memory" for one model means something else for another.
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

  @doc "The embedding space this embedder writes and reads (slice 133)."
  @callback space() :: Trinity.Memory.Space.t()

  @doc """
  The space's cosine thresholds (slice 133, AC11): `floor`, under which a vector hit is not
  recalled, and `dedupe`, at or over which a new memory is the same as an existing one.
  """
  @callback thresholds() :: %{floor: float(), dedupe: float()}

  @typedoc "An embedder as configuration names it."
  @type name :: :local | :static | :hosted | :fake | module()

  @doc """
  The configured choice: `:local` unless configuration says otherwise. Slice 133:
  `embedder:` may also be a list, the first being the one a re-tier targets and an empty store
  is first pinned to; the store is served by whichever configured embedder writes its active
  space, and by none when no configured embedder does (`Trinity.Memory.Semantic.status/0`).
  """
  @spec configured() :: name() | [name()]
  def configured, do: Application.get_env(:trinity, :memory, []) |> Keyword.get(:embedder, :local)

  @doc "Every configured embedder's module, in the configured order."
  @spec modules() :: [module()]
  def modules, do: configured() |> List.wrap() |> Enum.map(&module/1)

  @doc "The first configured embedder's module."
  @spec impl() :: module()
  def impl, do: hd(modules())

  @doc "The module an embedder name stands for."
  @spec module(name()) :: module()
  def module(:local), do: Trinity.Memory.Embedders.Bumblebee
  def module(:static), do: Trinity.Memory.Embedders.Static
  def module(:hosted), do: Trinity.Memory.Embedders.Hosted
  def module(:fake), do: Trinity.Memory.Embedders.Fake
  def module(module) when is_atom(module), do: module

  @names %{
    "local" => :local,
    "static" => :static,
    "hosted" => :hosted,
    "fake" => :fake
  }

  @doc "The embedder names an operator may type (a re-tier's target)."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@names) |> Enum.sort()

  @doc """
  The module for a typed name: one of `names/0`, or a configured embedder module by its name.
  Never mints an atom from the string.
  """
  @spec from_name(String.t()) :: {:ok, module()} | {:error, {:unknown_embedder, String.t()}}
  def from_name(name) when is_binary(name) do
    case Map.fetch(@names, name) do
      {:ok, atom} ->
        {:ok, module(atom)}

      :error ->
        case Enum.find(modules(), &(inspect(&1) == name)) do
          nil -> {:error, {:unknown_embedder, name}}
          module -> {:ok, module}
        end
    end
  end

  @doc "Embeds through the first configured embedder (`Trinity.Memory.Semantic` embeds through the one serving the store)."
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
