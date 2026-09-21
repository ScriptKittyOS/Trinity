# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedders.Hosted do
  @moduledoc """
  A provider's embedding endpoint through `Trinity.LLM.embed/2` (slice 032). A configured
  alternative only: `config :trinity, :memory, embedder: :hosted, hosted_model: "nvidia:embed"`.
  Text sent here leaves the machine, so this module is never selected on the operator's
  behalf (NOTES decisions 2 and 5), and `availability/0` says `{:off, :not_configured}` unless
  the configuration names it. The dimension is the model's, read from the first vector and
  kept for the run; `dim/0` before any call answers the configured `hosted_dim` (2048 for
  nemotron-3-embed-1b, measured at G1).
  """
  @behaviour Trinity.Memory.Embedder

  @dim_key {__MODULE__, :dim}

  @impl true
  def dim do
    :persistent_term.get(
      @dim_key,
      Application.get_env(:trinity, :memory, []) |> Keyword.get(:hosted_dim, 2048)
    )
  end

  @impl true
  def model_id, do: "hosted:" <> model()

  @impl true
  def availability do
    with :hosted <- Trinity.Memory.Embedder.configured(),
         {:ok, %{caps: caps}} when is_list(caps) <- Trinity.LLM.Registry.lookup(model()) do
      if :embed in caps, do: :ok, else: {:off, {:no_embed_capability, model()}}
    else
      {:error, reason} -> {:off, reason}
      _ -> {:off, :not_configured}
    end
  end

  @impl true
  def embed(texts) do
    with :ok <- availability(),
         {:ok, vectors} <- Trinity.LLM.embed(texts, model: model()) do
      case vectors do
        [v | _] -> :persistent_term.put(@dim_key, length(v))
        _ -> :ok
      end

      {:ok, vectors}
    end
  end

  defp model,
    do: Application.get_env(:trinity, :memory, []) |> Keyword.get(:hosted_model, "nvidia:embed")
end
