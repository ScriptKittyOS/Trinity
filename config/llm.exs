# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
import Config

# Slice 011: the model registry. Ids are Trinity's; `model` is req_llm's "provider:model";
# keys are read through Trinity.Config.secret/1 from the named variable at call time. Prices
# are US dollars per million tokens and are the source of every recorded cost. Free-tier
# models carry 0.0. The default model is the OpenRouter one the owner picked; the NVIDIA
# endpoint is reached as an OpenAI-compatible base_url. Test config replaces all of this.
# Slice 071: the default OpenRouter model takes images. llm_db's snapshot (the dependency in
# mix.lock) lists `openrouter` / `inclusionai/ling-3.0-flash-vl:free` with input modalities
# ["text", "image", "video"]. `:vision` is declared for that id only: a TRINITY_LIVE_MODEL naming
# another model gets no vision until someone checks that one and says so here.
ling_default = "inclusionai/ling-3.0-flash-vl:free"
ling_model = System.get_env("TRINITY_LIVE_MODEL", ling_default)
ling_vision = if ling_model == ling_default, do: [:vision], else: []

config :trinity, :llm,
  default_model: "openrouter:ling",
  providers: %{req_llm: Trinity.LLM.Providers.ReqLLM},
  retry: [attempts: 3, base_ms: 200],
  models: [
    %{
      id: "openrouter:ling",
      provider: :req_llm,
      model: "openrouter:" <> ling_model,
      api_key_env: "OPENROUTER_API_KEY",
      caps: [:stream, :tools, :json] ++ ling_vision,
      price: %{input: 0.0, output: 0.0}
    },
    %{
      id: "nvidia:nemotron",
      provider: :req_llm,
      model:
        "openai:" <> System.get_env("NEMOTRON_MODEL", "nvidia/nemotron-3.5-lightning-30b-a3b"),
      base_url: System.get_env("NEMOTRON_BASE_URL", "https://integrate.api.nvidia.com/v1"),
      api_key_env: "NEMOTRON_API_KEY",
      caps: [:stream, :tools, :json],
      price: %{input: 0.0, output: 0.0}
    },
    %{
      id: "nvidia:embed",
      provider: :req_llm,
      model: "openai:nvidia/nemotron-3-embed-1b",
      base_url: System.get_env("NEMOTRON_BASE_URL", "https://integrate.api.nvidia.com/v1"),
      api_key_env: "NEMOTRON_API_KEY",
      caps: [:embed],
      price: %{input: 0.0, output: 0.0}
    }
  ]
