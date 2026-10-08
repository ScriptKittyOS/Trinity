# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.EmbedderConfig do
  @moduledoc """
  The embedder configuration's faults (slice 133, D2-locality and D3's config half).

  Locality is declared by the operator and **never inferred from an address**: `localhost`, a
  private address or a cluster name says nothing about whether a component is inside the
  system's authorization boundary. So:

  * An in-process embedder (static, Bumblebee, the suite's fakes) runs in this BEAM by
    construction and is `:in_process`; a `locality:` declaring anything else is a fault.
  * An embedder with an endpoint (today the hosted one) must carry a declared `locality:`,
    `:within_boundary` or `:external`. None is a fault under **both** profiles, whatever the URL;
    `:in_process` is a fault (an endpoint is not in this process).
  * `:external` needs the operator's opt-in, `external_opt_in: true`, under both profiles: no
    memory text leaves for an external embedder unless the operator opted in for this deployment.
  * Under `:regulated` only, the endpoint must be stated and on `TRINITY_REGULATED_LLM_ENDPOINTS`
    (`:not_allow_listed` otherwise), for `:within_boundary` and `:external` alike.

  Pure, like `Trinity.Profile`: the caller reads the world and hands the values in. Under
  `:regulated` `Trinity.Application` refuses the boot on a fault; under `:default` the boot goes
  on and `Trinity.Memory.Semantic.status/0` is `{:off, {:config, reason}}`.
  """

  alias Trinity.Memory.Embedder

  @localities [:in_process, :within_boundary, :external]

  @doc """
  `:ok`, or the first fault, for the configured embedders. `memory` is `config :trinity,
  :memory`, `models` the LLM registry's models, `raw_endpoints` the allow-list variable.
  """
  @spec check(Trinity.Profile.t(), keyword(), [map()], String.t() | nil) :: :ok | {:error, term()}
  def check(profile, memory, models, raw_endpoints) do
    memory
    |> Keyword.get(:embedder, :local)
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case check_one(profile, name, memory, models, raw_endpoints) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_one(profile, name, memory, models, raw) do
    declared = Keyword.get(memory, :locality)

    case endpoint(Embedder.module(name), memory, models) do
      :in_process ->
        if declared in [nil, :in_process],
          do: :ok,
          else: {:error, {:embedder_locality_mismatch, name, declared}}

      {:endpoint, url} ->
        check_endpoint(profile, name, url, declared, memory, raw)
    end
  end

  defp check_endpoint(_profile, name, url, nil, _memory, _raw),
    do: {:error, {:embedder_locality_undeclared, name, url}}

  defp check_endpoint(_profile, name, _url, :in_process, _memory, _raw),
    do: {:error, {:embedder_locality_in_process_with_endpoint, name}}

  defp check_endpoint(_profile, name, _url, declared, _memory, _raw)
       when declared not in @localities,
       do: {:error, {:embedder_locality_invalid, name, declared}}

  defp check_endpoint(profile, name, url, :external, memory, raw) do
    if Keyword.get(memory, :external_opt_in) == true,
      do: allow_listed(profile, name, url, raw),
      else: {:error, {:external_not_opted_in, name}}
  end

  defp check_endpoint(profile, name, url, :within_boundary, _memory, raw),
    do: allow_listed(profile, name, url, raw)

  defp allow_listed(:default, _name, _url, _raw), do: :ok

  defp allow_listed(:regulated, name, url, raw) do
    allowed = Trinity.Profile.allowed_endpoints(raw)

    case URI.parse(to_string(url)) do
      %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) and h != "" ->
        if {s, h} in allowed,
          do: :ok,
          else: {:error, {:not_allow_listed, name, "#{s}://#{h}"}}

      _ ->
        {:error, {:embedder_endpoint_unstated, name}}
    end
  end

  # Whether an embedder reaches an endpoint, and which. Only the hosted embedder does today; its
  # URL is its registry model's `base_url` (nil when the provider's default endpoint is used,
  # which `:regulated` refuses as unstated).
  defp endpoint(Trinity.Memory.Embedders.Hosted, memory, models) do
    model = Keyword.get(memory, :hosted_model, "nvidia:embed")

    url =
      Enum.find_value(models, fn m -> if Map.get(m, :id) == model, do: Map.get(m, :base_url) end)

    {:endpoint, url}
  end

  defp endpoint(_in_process, _memory, _models), do: :in_process
end
