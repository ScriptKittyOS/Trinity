# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedders.Bumblebee do
  @moduledoc """
  all-MiniLM-L6-v2 on this machine through Bumblebee and EXLA (slice 032): 384 dimensions,
  mean pooling, L2-normalised; measured at G1 at 86 ms a sentence and 2.7 ms an item in a
  batch of 32, with cosines 0.858 and 0.062 on the slice's two pairs. The serving runs under
  `Trinity.Memory.Supervisor` as `Trinity.Memory.Embedding` when the model is present.

  **The model is not downloaded on its own.** `availability/0` answers `{:off, :model_missing}`
  until `download/0` (an explicit action, on the memory page or by `mix trinity.embeddings.download`)
  has put the 91 MB of weights and tokenizer files under the model cache
  (`config :trinity, :memory, model_cache_dir:`, the data directory's `models/` by default;
  `BUMBLEBEE_CACHE_DIR` overrides). On Windows, where XLA has no precompiled library,
  `{:off, :no_local_backend}`; a missing or broken EXLA NIF, `{:off, {:exla, reason}}`. None of
  these turns into a hosted call (NOTES decision 2).
  """
  @behaviour Trinity.Memory.Embedder

  @repo "sentence-transformers/all-MiniLM-L6-v2"
  @dim 384
  @serving Trinity.Memory.Embedding

  @impl true
  def dim, do: @dim

  @impl true
  def model_id, do: "bumblebee:" <> @repo

  @doc "The Hugging Face repository the weights come from."
  @spec repo() :: String.t()
  def repo, do: @repo

  @doc "The serving's registered name."
  @spec serving_name() :: atom()
  def serving_name, do: @serving

  @doc "The model cache directory in force."
  @spec cache_dir() :: Path.t()
  def cache_dir do
    System.get_env("BUMBLEBEE_CACHE_DIR") ||
      Application.get_env(:trinity, :memory, [])[:model_cache_dir] ||
      Path.join(Trinity.Paths.data_dir(), "models")
  end

  @impl true
  def availability do
    cond do
      match?({:win32, _}, :os.type()) -> {:off, :no_local_backend}
      not Code.ensure_loaded?(EXLA) -> {:off, {:exla, :not_compiled}}
      not model_present?() -> {:off, :model_missing}
      true -> :ok
    end
  end

  @doc "True when the weights and tokenizer are in the cache (checked offline, no request made)."
  @spec model_present?() :: boolean()
  def model_present? do
    case load(offline: true) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @impl true
  def embed(texts) do
    case Process.whereis(@serving) do
      nil ->
        {:error, {:embedder_off, availability()}}

      _pid ->
        try do
          results = Nx.Serving.batched_run(@serving, texts)
          {:ok, Enum.map(results, &Nx.to_flat_list(&1.embedding))}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
    end
  end

  @doc """
  The `Nx.Serving` for the supervisor, or `{:error, reason}` when the model is not present.
  Loading takes about 650 ms; the first embed compiles the graph (318 ms measured).
  """
  @spec serving() :: {:ok, Nx.Serving.t()} | {:error, term()}
  def serving do
    with {:ok, model_info, tokenizer} <- load(offline: true) do
      {:ok,
       Bumblebee.Text.text_embedding(model_info, tokenizer,
         compile: [batch_size: 32, sequence_length: 128],
         defn_options: [compiler: EXLA],
         output_pool: :mean_pooling,
         output_attribute: :hidden_state,
         embedding_processor: :l2_norm
       )}
    end
  end

  @doc """
  Downloads the model into the cache (a network egress the operator asked for), then asks
  the supervisor to start the serving. Returns `:ok` or the download's error.
  """
  @spec download() :: :ok | {:error, term()}
  def download do
    with {:ok, _, _} <- load(offline: false) do
      Trinity.Memory.Supervisor.ensure_embedding()
    end
  end

  defp load(opts) do
    repo = {:hf, @repo, cache_dir: cache_dir(), offline: Keyword.get(opts, :offline, true)}

    with {:ok, model_info} <- Bumblebee.load_model(repo),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(repo) do
      {:ok, model_info, tokenizer}
    end
  rescue
    e -> {:error, {:load, Exception.message(e)}}
  end
end
