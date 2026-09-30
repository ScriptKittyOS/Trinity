# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Profile do
  @moduledoc """
  The deployment profile, and the refusals `:regulated` adds to boot.

  Two profiles. `:default` is everything this tree did before and behaves exactly as it did.
  `:regulated` refuses to start in a configuration that cannot support a regulated deployment,
  on the reasoning that an operator who has set the wrong thing should find out at boot and not
  from an auditor.

  ## Every function here is pure, and that is deliberate

  Nothing in this module reads the environment except `current/0` and `raw_endpoints/0`, and
  nothing starts, stops or touches a process. The caller reads the world and hands the values in.
  Two reasons: a refusal that cannot be unit tested is a refusal nobody has checked, and this
  module sits in the `Trinity` boundary, which does not depend on `Trinity.Authority` or
  `Trinity.Receipts` and should not grow a dependency on them to ask a question about a value.

  ## `:default` is never changed by anything here

  Every check takes the profile as its first argument and answers `:ok` for `:default` without
  looking at anything else. `Trinity.Receipts.Supervisor` keeps its fail-open shape for every
  profile that is not `:regulated`: a missing signer logs, sets `Trinity.Receipts.Alarm`, and lets
  the tree start, because every effect is denied until a signer returns. That is right for a
  personal machine and wrong for a regulated one, and the difference is expressed here rather than
  by changing the supervisor.
  """

  @type t :: :default | :regulated

  @env "TRINITY_PROFILE"
  @endpoints_env "TRINITY_REGULATED_LLM_ENDPOINTS"

  @doc """
  The profile in force: `#{@env}`, else `config :trinity, :profile`, else `:default`.

  An unrecognised value raises rather than falling back. A typo in a profile name must not
  silently produce the permissive profile, which is the one failure mode this whole module exists
  to prevent.
  """
  @spec current() :: t()
  def current do
    case System.get_env(@env) do
      nil -> Application.get_env(:trinity, :profile, :default)
      "" -> Application.get_env(:trinity, :profile, :default)
      "regulated" -> :regulated
      "default" -> :default
      other -> raise ArgumentError, "#{@env} is not default or regulated: #{inspect(other)}"
    end
  end

  @doc "True when the profile in force is `:regulated`."
  @spec regulated?() :: boolean()
  def regulated?, do: current() == :regulated

  @doc "The raw value of `#{@endpoints_env}`, unparsed."
  @spec raw_endpoints() :: String.t() | nil
  def raw_endpoints, do: System.get_env(@endpoints_env)

  @doc "The name of the endpoint allow-list variable, so an error message and a test agree on it."
  @spec endpoints_env() :: String.t()
  def endpoints_env, do: @endpoints_env

  @doc """
  AC1. Under `:regulated` the MCP authorization profile must be `:production`.

  `:local` trusts a bearer token in a file on the host and `:personal` runs an authorization
  server on the owner's machine. Neither is an identity provider a regulated boundary can point
  at, so neither may be the one in force.
  """
  @spec check_mcp_auth(t(), atom()) :: :ok | {:error, term()}
  def check_mcp_auth(:default, _mcp_auth_profile), do: :ok
  def check_mcp_auth(:regulated, :production), do: :ok

  def check_mcp_auth(:regulated, got),
    do: {:error, {:regulated_requires_production_mcp_auth, got}}

  @doc """
  AC2. Under `:regulated` the embedded, personal authorization server must not be the one in force.

  This is decided here, before `Trinity.MCP.Boot` runs, because that module ends in a rescue that
  turns any failure into a warning log. A warning is not a refusal, and the rescue is not narrowed
  to make this work.
  """
  @spec check_embedded_as(t(), atom()) :: :ok | {:error, term()}
  def check_embedded_as(:default, _mcp_auth_profile), do: :ok
  def check_embedded_as(:regulated, :personal), do: {:error, :regulated_refuses_personal_issuer}
  def check_embedded_as(:regulated, _other), do: :ok

  @doc """
  AC5. Under `:regulated` the authority in force must not be `Trinity.Authority.Local`.

  **No external adapter is supplied by this tree and none is invented here.** If `TRINITY_AUTHORITY`
  is unset, or names something that resolves to `Local`, the boot is refused. The refusal is the
  point: a regulated boundary where the machine is judge, actor and scribe is the configuration
  this profile exists to stop, and the operator has to supply an adapter for it to start.
  """
  @spec check_authority(t(), module()) :: :ok | {:error, term()}
  def check_authority(:default, _module), do: :ok

  def check_authority(:regulated, Trinity.Authority.Local),
    do: {:error, :regulated_refuses_local_authority}

  def check_authority(:regulated, module) when is_atom(module) and not is_nil(module), do: :ok

  # Owner ruling 2026-09-30. Without this clause the function was partial, and the one caller
  # that could reach the gap did. `Trinity.Application` resolved the authority through
  # `Selection.select/1` and turned any refusal into `nil`, so an unloadable TRINITY_AUTHORITY
  # under `:regulated` arrived here as `nil`, matched no clause, and the boot died with a
  # FunctionClauseError naming this function instead of naming the variable the operator set.
  # The caller now reports the selection's own reason; this clause makes the refusal total
  # rather than relying on every caller to be careful.
  def check_authority(:regulated, other), do: {:error, {:regulated_authority_unresolved, other}}

  @doc """
  AC4. Under `:regulated`, receipts that cannot be appended at boot stop the node.

  `boot_result` is what `Trinity.Receipts.KeyCustody.boot!/1` answered. Under `:default` this
  returns `:ok` whatever it was, which is the existing behaviour and is not changed: the supervisor
  logs, sets the alarm, and the tree starts with every effect denied.
  """
  @spec check_receipts(t(), {:ok, term()} | {:error, term()}) :: :ok | {:error, term()}
  def check_receipts(:default, _boot_result), do: :ok
  def check_receipts(:regulated, {:ok, _selection}), do: :ok

  def check_receipts(:regulated, {:error, reason}),
    do: {:error, {:regulated_requires_receipts, reason}}

  @doc """
  AC3. Under `:regulated` every configured model must name an endpoint on the allow-list.

  `raw` is `#{@endpoints_env}`, a comma separated list of scheme and host, for example
  `https://models.internal,https://gateway.lab.example`. `models` is `config :trinity, :llm`'s
  `:models` list.

  **A model with no `base_url` is refused**, and that is not an oversight. Such a model goes to its
  provider's default endpoint, which this configuration does not state, and an endpoint that is not
  stated cannot be shown to be on the list. Under `:regulated` "we cannot tell where this goes" is
  a refusal.
  """
  @spec check_llm_endpoints(t(), String.t() | nil, [map()]) :: :ok | {:error, term()}
  def check_llm_endpoints(:default, _raw, _models), do: :ok

  def check_llm_endpoints(:regulated, raw, _models) when raw in [nil, ""],
    do: {:error, {:regulated_llm_endpoints_unset, @endpoints_env}}

  def check_llm_endpoints(:regulated, raw, models) do
    case allowed_endpoints(raw) do
      [] ->
        {:error, {:regulated_llm_endpoints_unset, @endpoints_env}}

      allowed ->
        Enum.reduce_while(models, :ok, &first_refusal(&1, &2, allowed))
    end
  end

  defp first_refusal(model, :ok, allowed) do
    case check_model(model, allowed) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  @doc """
  Parses the allow-list into `{scheme, host}` pairs, dropping anything that is not a scheme and a
  host. A malformed entry is dropped rather than widening the list.
  """
  @spec allowed_endpoints(String.t() | nil) :: [{String.t(), String.t()}]
  def allowed_endpoints(nil), do: []

  def allowed_endpoints(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn entry ->
      case URI.parse(entry) do
        %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) and h != "" -> [{s, h}]
        _ -> []
      end
    end)
  end

  defp check_model(model, allowed) do
    id = Map.get(model, :id, "(no id)")
    url = Map.get(model, :base_url)

    if url in [nil, ""],
      do: {:error, {:regulated_llm_endpoint_unstated, id}},
      else: check_url(id, url, allowed)
  end

  defp check_url(id, url, allowed) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) and h != "" ->
        if {s, h} in allowed,
          do: :ok,
          else: {:error, {:regulated_llm_endpoint_not_allowed, id, "#{s}://#{h}"}}

      _ ->
        {:error, {:regulated_llm_endpoint_unparseable, id, url}}
    end
  end
end
