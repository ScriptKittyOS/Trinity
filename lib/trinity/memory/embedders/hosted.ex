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

  @doc """
  Slice 133: the space of a provider's model. The provider pools, normalises and versions the
  weights out of sight, so those fields are `"provider"` or `"unrecorded"`; the operator's
  declared `locality:` is part of it, so declaring another locality is another space.
  """
  @impl true
  def space do
    u = "unrecorded"

    %Trinity.Memory.Space{
      model_id: model_id(),
      revision: u,
      weights_digest: u,
      tokenizer_digest: u,
      dim: dim(),
      pooling: "provider",
      normalisation: u,
      quantization: "f32",
      query_prompt: "",
      document_prompt: "",
      max_input_tokens: u,
      truncation: u,
      runtime: "req_llm",
      runtime_version: to_string(Application.spec(:req_llm, :vsn) || u),
      locality: (Application.get_env(:trinity, :memory, [])[:locality] || u) |> to_string(),
      num_ctx: "none"
    }
  end

  @doc """
  The endpoint: the registry model's `base_url` (nil when the provider's default endpoint is
  used, which `:regulated` refuses as unstated). Slice 134 moved this here from
  `Trinity.Memory.EmbedderConfig`, unchanged, as the `endpoint/2` callback.
  """
  @impl true
  def endpoint(memory, models) do
    model = Keyword.get(memory, :hosted_model, "nvidia:embed")

    url =
      Enum.find_value(models, fn m -> if Map.get(m, :id) == model, do: Map.get(m, :base_url) end)

    {:endpoint, url}
  end

  @doc "Not measured for any hosted model (slice 032 G1: nemotron's raw vectors do not separate)."
  @impl true
  def thresholds do
    Application.get_env(:trinity, :memory, [])
    |> Keyword.get(:hosted_thresholds, %{floor: 0.3, dedupe: 0.92})
  end

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
