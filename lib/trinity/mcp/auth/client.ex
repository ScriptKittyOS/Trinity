# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Client do
  @moduledoc """
  The OAuth 2.1 client role (slice 062, ADR-0007 decision 8): how Trinity obtains a token for a
  protected MCP server, so that 060's driver can present it and perform no flow of its own.

  On a `401` whose `WWW-Authenticate` names `resource_metadata`, the driver hands the URL here:
  the Protected Resource Metadata (RFC 9728) names the authorization server; its metadata (RFC
  8414, OIDC second) names the endpoints; `begin/3` builds the authorization URL with PKCE (S256),
  `state`, the `resource` (RFC 8707) and the client's identity, holds the request in the store,
  and the owner opens the URL; `finish/2` takes the callback (`state` to the pending request,
  `iss` checked against the issuer when the AS says it sends one, RFC 9207), exchanges the code
  at the token endpoint with the verifier and the resource, and stores the token for the
  resource. The client identifies itself by the configured `client_id` (pre-registered at the
  enterprise AS, the production path), by a Client ID Metadata Document URL when configured, or,
  behind `dcr: true` and only when the AS offers registration, by registering once.
  """

  alias Trinity.MCP.Auth.Client.Store
  alias Trinity.MCP.Auth.{Config, Discovery}

  @default_scope "trinity:tools:read"

  @doc "The `resource_metadata` URL a `WWW-Authenticate: Bearer …` challenge names."
  @spec challenge(String.t() | [String.t()]) :: {:ok, String.t()} | :error
  def challenge([header | _]), do: challenge(header)

  def challenge(header) when is_binary(header) do
    case Regex.run(~r/resource_metadata="([^"]+)"/, header) do
      [_, url] -> {:ok, url}
      _ -> :error
    end
  end

  def challenge(_), do: :error

  @doc "The resource and its authorization server's metadata, from the PRM's URL."
  @spec discover(String.t(), keyword()) ::
          {:ok, %{resource: String.t(), issuer: String.t(), as: map()}} | {:error, term()}
  def discover(prm_url, opts \\ []) do
    with {:ok, %{"resource" => resource, "authorization_servers" => [issuer | _]}} <-
           Discovery.protected_resource(prm_url, opts),
         {:ok, as} <- Discovery.authorization_server(issuer, opts) do
      {:ok, %{resource: resource, issuer: issuer, as: as}}
    else
      {:ok, _} -> {:error, :no_authorization_server_in_metadata}
      {:error, _} = error -> error
    end
  end

  @doc """
  Begins the code flow for a discovered server: the URL the owner opens. `redirect_uri` is the
  host's callback; `scope` the scopes asked (`trinity:tools:read` by default).
  """
  @spec begin(map(), Config.t(), keyword()) ::
          {:ok, %{url: String.t(), state: String.t()}} | {:error, term()}
  def begin(%{resource: resource, issuer: issuer, as: as}, %Config{} = config, opts) do
    with {:ok, client_id} <- client_id(as, issuer, config, opts),
         {:ok, endpoint} <- fetch(as, "authorization_endpoint") do
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      redirect_uri = Keyword.fetch!(opts, :redirect_uri)
      scope = Keyword.get(opts, :scope, @default_scope)

      params = %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "resource" => resource,
        "scope" => scope
      }

      :ok =
        Store.put_pending(config.store_dir, state, %{
          "verifier" => verifier,
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "resource" => resource,
          "issuer" => issuer,
          "token_endpoint" => as["token_endpoint"],
          "iss_expected" => as["authorization_response_iss_parameter_supported"] == true
        })

      {:ok, %{url: endpoint <> "?" <> URI.encode_query(params), state: state}}
    end
  end

  @doc "Finishes the flow from the callback's params: the token stored for the resource."
  @spec finish(map(), Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(params, %Config{} = config, opts \\ []) do
    with {:ok, state} <- fetch(params, "state"),
         {:ok, pending} <- Store.take_pending(config.store_dir, state) |> ok_or(:unknown_state),
         :ok <- issuer_check(params, pending),
         :ok <- error_check(params),
         {:ok, code} <- fetch(params, "code"),
         {:ok, token} <- exchange(code, pending, opts) do
      entry = %{
        "issuer" => pending["issuer"],
        "resource" => pending["resource"],
        "access_token" => token["access_token"],
        "expires_at" => System.os_time(:second) + (token["expires_in"] || 300),
        "scope" => token["scope"]
      }

      :ok = Store.put_token(config.store_dir, pending["resource"], entry)
      {:ok, Map.delete(entry, "access_token")}
    end
  end

  @doc "The stored bearer for a resource, if one is held and not expired."
  @spec bearer(Config.t(), String.t()) :: String.t() | nil
  def bearer(%Config{store_dir: dir}, resource) when is_binary(dir) do
    case Store.token(dir, resource) do
      {:ok, %{"access_token" => t}} -> t
      :error -> nil
    end
  end

  def bearer(_config, _resource), do: nil

  # RFC 9207: when the AS says it sends `iss`, the callback must carry the issuer expected;
  # a callback from another issuer is a mix-up and is refused.
  defp issuer_check(params, %{"iss_expected" => true, "issuer" => issuer}) do
    if params["iss"] == issuer, do: :ok, else: {:error, {:wrong_issuer, params["iss"]}}
  end

  defp issuer_check(params, %{"issuer" => issuer}) do
    case params["iss"] do
      nil -> :ok
      ^issuer -> :ok
      other -> {:error, {:wrong_issuer, other}}
    end
  end

  defp error_check(%{"error" => error} = params),
    do: {:error, {:authorization_error, error, params["error_description"]}}

  defp error_check(_), do: :ok

  defp exchange(code, pending, opts) do
    form = [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: pending["redirect_uri"],
      client_id: pending["client_id"],
      code_verifier: pending["verifier"],
      resource: pending["resource"]
    ]

    options =
      Keyword.merge(
        [form: form, retry: false, decode_body: false, receive_timeout: 10_000],
        Keyword.get(opts, :req_options, [])
      )

    case Req.post(pending["token_endpoint"], options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => t} = token} when is_binary(t) -> {:ok, token}
          _ -> {:error, :token_response_unreadable}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:token_endpoint, status, describe(body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp describe(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => e}} -> e
      _ -> binary_part(body, 0, min(byte_size(body), 120))
    end
  end

  defp describe(other), do: inspect(other)

  # The client's identity, in order: the configured id; the metadata document's URL; a
  # registration made once and remembered, only when allowed and offered.
  defp client_id(as, issuer, %Config{} = config, opts) do
    cond do
      is_binary(config.client_id) ->
        {:ok, config.client_id}

      is_binary(config.client_metadata_url) ->
        {:ok, config.client_metadata_url}

      id = Store.client_id(config.store_dir, issuer) ->
        {:ok, id}

      config.dcr and is_binary(as["registration_endpoint"]) ->
        register(as["registration_endpoint"], issuer, config, opts)

      true ->
        {:error, :no_client_identity}
    end
  end

  defp register(endpoint, issuer, config, opts) do
    body = %{
      "client_name" => "Trinity",
      "redirect_uris" => [Keyword.fetch!(opts, :redirect_uri)],
      "token_endpoint_auth_method" => "none",
      "grant_types" => ["authorization_code"],
      "response_types" => ["code"]
    }

    case Req.post(endpoint, json: body, retry: false, decode_body: false) do
      {:ok, %Req.Response{status: status, body: raw}} when status in [200, 201] ->
        case Jason.decode(raw) do
          {:ok, %{"client_id" => id}} ->
            :ok = Store.put_client_id(config.store_dir, issuer, id)
            {:ok, id}

          _ ->
            {:error, :registration_unreadable}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:registration_refused, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp fetch(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, key}}
    end
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, reason), do: {:error, reason}
end
