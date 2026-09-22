# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Embedded do
  @moduledoc """
  The personal profile (slice 062): the resource server of `External` plus a small authorization
  server on the owner's machine, for the owner's own MCP clients. Not the default, and refused
  where it must be: `start_link/1` refuses when the host says an external authority adapter is
  in force (`Config.local_authority?` false), so a regulated deployment has no embedded issuer
  by construction; every token it mints carries `"profile" => "personal"`, which the production
  profile refuses whatever key signed it.

  What it speaks: RFC 8414 metadata; authorization-code with PKCE (S256 only) and RFC 8707
  `resource` (this server's identifier, required); the owner's consent in the browser as the
  login (the local Trinity user); RFC 9207 `iss` on the response; Client ID Metadata Documents
  (the `client_id` is the https URL of the client's metadata, fetched and checked) with RFC 7591
  registration only behind `dcr: true`; ES256 access tokens with `aud` = the resource identifier,
  ten minutes of life, the JWKS at the host's route, rotation by `kid` (`Embedded.Keys`).

  This process holds the pending authorization requests and the issued codes (single use, ten
  minutes); the personal profile is one instance, so memory is its store. Registered clients
  (DCR) live in `mcp-as-clients.json` beside the keys.
  """
  @behaviour Trinity.MCP.Auth
  use GenServer

  alias Trinity.MCP.Auth
  alias Trinity.MCP.Auth.{Config, Discovery, Principal, Scopes, Token}
  alias Trinity.MCP.Auth.Embedded.Keys

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @code_ttl_s 600
  @request_ttl_s 600
  @cimd_ttl_s 3_600
  @loopback_hosts ["127.0.0.1", "localhost", "::1"]

  ## The behaviour (the resource server half)

  @impl Trinity.MCP.Auth
  def authorize(conn, %Config{} = config) do
    with {:ok, token} <- Auth.bearer(conn),
         {:ok, header} <- Token.header(token),
         {:ok, entry} <- key_for(config, header["kid"]) do
      Token.verify_with_key(token, entry.jwk, %{config | issuer: issuer(config)})
    end
  end

  @impl Trinity.MCP.Auth
  def resource_metadata(%Config{} = config) do
    %{
      "resource" => config.resource,
      "authorization_servers" => [issuer(config)],
      "bearer_methods_supported" => ["header"],
      "scopes_supported" => Scopes.known()
    }
  end

  defp key_for(%Config{key_dir: dir}, kid) when is_binary(kid) do
    case Keys.find(dir, kid) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_kid, kid}}
    end
  end

  defp key_for(_config, nil), do: {:error, :no_kid}

  @doc "The issuer of the personal profile: the configured one, else the resource identifier's origin."
  @spec issuer(Config.t()) :: String.t()
  def issuer(%Config{issuer: issuer}) when is_binary(issuer), do: issuer

  def issuer(%Config{resource: resource}) do
    uri = URI.parse(resource)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string()
  end

  ## The authorization server half: metadata

  @doc "The RFC 8414 metadata; the endpoints are the host's routes under the issuer."
  @spec metadata(Config.t()) :: map()
  def metadata(%Config{} = config) do
    iss = issuer(config)

    %{
      "issuer" => iss,
      "authorization_endpoint" => iss <> "/oauth/authorize",
      "token_endpoint" => iss <> "/oauth/token",
      "jwks_uri" => iss <> "/.well-known/jwks.json",
      "registration_endpoint" => if(config.dcr, do: iss <> "/oauth/register"),
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "scopes_supported" => Scopes.known(),
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true,
      "resource_indicators_supported" => true
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "The JWKS document."
  @spec jwks(Config.t()) :: map()
  def jwks(%Config{key_dir: dir}), do: Keys.jwks(dir)

  ## The process

  @doc "Starts the authorization server's state; refused under an external authority adapter."
  @spec start_link(Config.t()) :: GenServer.on_start() | {:error, :external_authority_in_force}
  def start_link(%Config{} = config) do
    if config.local_authority? do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    else
      {:error, :external_authority_in_force}
    end
  end

  @impl GenServer
  def init(config) do
    Keys.ensure!(config.key_dir)
    {:ok, %{config: config, requests: %{}, codes: %{}, clients: load_clients(config), cimd: %{}}}
  end

  ## Authorization requests

  @typedoc "What the consent page shows: the request id, the client's name, the scopes asked."
  @type pending :: %{
          id: String.t(),
          client_id: String.t(),
          client_name: String.t(),
          scope: [String.t()],
          resource: String.t()
        }

  @doc """
  Validates an authorization request (the query of `GET /oauth/authorize`) and holds it for the
  owner's consent: the client known (CIMD or registered), the redirect URI one of the client's,
  PKCE S256 present, `resource` this server's identifier, the scopes known. The reply names the
  pending request for the consent page, or the refusal (with the redirect to send it to when the
  redirect URI itself was fine).
  """
  @spec begin(map()) :: {:ok, pending()} | {:error, term()} | {:redirect_error, String.t()}
  def begin(params) when is_map(params), do: GenServer.call(__MODULE__, {:begin, params})

  @doc "The owner's decision on a pending request: the URL to send the client to."
  @spec decide(String.t(), :approve | :deny, String.t()) :: {:ok, String.t()} | {:error, term()}
  def decide(request_id, decision, sub) when decision in [:approve, :deny],
    do: GenServer.call(__MODULE__, {:decide, request_id, decision, sub})

  @doc "The token endpoint: an authorization code with its verifier for an access token."
  @spec token(map()) :: {:ok, map()} | {:error, term()}
  def token(params) when is_map(params), do: GenServer.call(__MODULE__, {:token, params})

  @doc "RFC 7591 registration, when enabled: the client's metadata for its id."
  @spec register(map()) :: {:ok, map()} | {:error, term()}
  def register(metadata) when is_map(metadata),
    do: GenServer.call(__MODULE__, {:register, metadata})

  @doc "The registered clients (DCR), by id."
  @spec clients() :: %{String.t() => map()}
  def clients, do: GenServer.call(__MODULE__, :clients)

  @impl GenServer
  def handle_call({:begin, params}, _from, state) do
    now = System.os_time(:second)
    state = expire(state, now)

    case validate_request(params, state) do
      {:ok, client, state} ->
        id = random()

        pending = %{
          id: id,
          client_id: params["client_id"],
          client_name: client["client_name"] || params["client_id"],
          scope: Principal.scopes(params["scope"]),
          resource: params["resource"],
          redirect_uri: params["redirect_uri"],
          state: params["state"],
          code_challenge: params["code_challenge"],
          exp: now + @request_ttl_s
        }

        {:reply, {:ok, Map.take(pending, [:id, :client_id, :client_name, :scope, :resource])},
         put_in(state.requests[id], pending)}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:redirect_error, url, state} ->
        {:reply, {:redirect_error, url}, state}
    end
  end

  def handle_call({:decide, id, decision, sub}, _from, state) do
    now = System.os_time(:second)
    state = expire(state, now)

    case Map.pop(state.requests, id) do
      {nil, _} ->
        {:reply, {:error, :unknown_request}, state}

      {pending, requests} ->
        state = %{state | requests: requests}

        case decision do
          :deny ->
            {:reply,
             {:ok,
              redirect(pending.redirect_uri,
                error: "access_denied",
                state: pending.state,
                iss: issuer(state.config)
              )}, state}

          :approve ->
            code = random()

            entry = %{
              client_id: pending.client_id,
              redirect_uri: pending.redirect_uri,
              code_challenge: pending.code_challenge,
              resource: pending.resource,
              scope: pending.scope,
              sub: sub,
              exp: now + @code_ttl_s
            }

            url =
              redirect(pending.redirect_uri,
                code: code,
                state: pending.state,
                iss: issuer(state.config)
              )

            {:reply, {:ok, url}, put_in(state.codes[code], entry)}
        end
    end
  end

  def handle_call({:token, params}, _from, state) do
    now = System.os_time(:second)
    state = expire(state, now)

    with "authorization_code" <- Map.get(params, "grant_type", "authorization_code"),
         {entry, codes} when is_map(entry) <- Map.pop(state.codes, params["code"]),
         state = %{state | codes: codes},
         :ok <- same(entry.client_id, params["client_id"], :invalid_client),
         :ok <- same(entry.redirect_uri, params["redirect_uri"], :invalid_redirect_uri),
         :ok <- same(entry.resource, params["resource"] || entry.resource, :invalid_target),
         :ok <- pkce(entry.code_challenge, params["code_verifier"]) do
      {:reply, {:ok, issue(entry, state.config, now)}, state}
    else
      {nil, _} -> {:reply, {:error, :invalid_grant}, state}
      grant when is_binary(grant) -> {:reply, {:error, :unsupported_grant_type}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register, _metadata}, _from, %{config: %{dcr: false}} = state),
    do: {:reply, {:error, :registration_disabled}, state}

  def handle_call({:register, metadata}, _from, state) do
    case redirect_uris(metadata["redirect_uris"]) do
      {:ok, uris} ->
        client_id = "dcr-" <> random()

        client = %{
          "client_id" => client_id,
          "client_name" => metadata["client_name"] || client_id,
          "redirect_uris" => uris,
          "token_endpoint_auth_method" => "none",
          "grant_types" => ["authorization_code"],
          "response_types" => ["code"]
        }

        state = put_in(state.clients[client_id], client)
        save_clients(state)
        {:reply, {:ok, client}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clients, _from, state), do: {:reply, state.clients, state}

  ## Validation

  defp validate_request(params, state) do
    with :ok <- required(params, ~w(client_id redirect_uri response_type code_challenge resource)),
         :ok <- same(params["response_type"], "code", :unsupported_response_type),
         :ok <-
           same(params["code_challenge_method"] || "S256", "S256", :invalid_code_challenge_method),
         {:ok, client, state} <- client(params["client_id"], state),
         :ok <- redirect_allowed(client, params["redirect_uri"]) do
      cond do
        params["resource"] != state.config.resource ->
          {:redirect_error,
           redirect(params["redirect_uri"],
             error: "invalid_target",
             state: params["state"],
             iss: issuer(state.config)
           ), state}

        not Enum.all?(Principal.scopes(params["scope"]), &(&1 in Scopes.known())) ->
          {:redirect_error,
           redirect(params["redirect_uri"],
             error: "invalid_scope",
             state: params["state"],
             iss: issuer(state.config)
           ), state}

        true ->
          {:ok, client, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp required(params, keys) do
    case Enum.reject(keys, &(is_binary(params[&1]) and params[&1] != "")) do
      [] -> :ok
      missing -> {:error, {:invalid_request, "missing " <> Enum.join(missing, ", ")}}
    end
  end

  defp same(a, a, _), do: :ok
  defp same(_, _, reason), do: {:error, reason}

  # A client is a registered one (DCR) or a Client ID Metadata Document: the id is an https
  # URL whose document names itself and its redirect URIs, fetched once an hour. The one
  # http exception is a loopback host (RFC 8252 section 7.3's reasoning: a process on this
  # machine, which in the personal profile is the owner's), so a local client can publish its
  # document without a certificate; recorded in NOTES as the deviation from the CIMD draft.
  defp client(client_id, state) do
    cond do
      Map.has_key?(state.clients, client_id) ->
        {:ok, state.clients[client_id], state}

      cimd_url?(client_id) ->
        cimd(client_id, state)

      true ->
        {:error, :unknown_client, state}
    end
  end

  defp cimd_url?(client_id) do
    case URI.new(client_id) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> true
      {:ok, %URI{scheme: "http", host: host}} -> host in @loopback_hosts
      _ -> false
    end
  end

  defp cimd(url, state) do
    now = System.os_time(:second)

    case Map.get(state.cimd, url) do
      {doc, at} when now - at < @cimd_ttl_s ->
        {:ok, doc, state}

      _ ->
        case Discovery.fetch_json(url) do
          {:ok, %{"client_id" => ^url, "redirect_uris" => uris} = doc} when is_list(uris) ->
            {:ok, doc, put_in(state.cimd[url], {doc, now})}

          {:ok, _} ->
            {:error, {:invalid_client_metadata, url}, state}

          {:error, reason} ->
            {:error, {:client_metadata_unreachable, reason}, state}
        end
    end
  end

  # A registered redirect URI matches exactly; a loopback one (RFC 8252 section 7.3) matches
  # with any port, since a native client binds an ephemeral one.
  defp redirect_allowed(%{"redirect_uris" => uris}, given) when is_list(uris) do
    if Enum.any?(uris, &redirect_match?(&1, given)),
      do: :ok,
      else: {:error, :invalid_redirect_uri}
  end

  defp redirect_allowed(_, _), do: {:error, :invalid_redirect_uri}

  defp redirect_match?(registered, given) when registered == given, do: true

  defp redirect_match?(registered, given) do
    with %URI{scheme: "http", host: rh} = r <- URI.parse(registered),
         %URI{scheme: "http", host: gh} = g <- URI.parse(given),
         true <- rh in @loopback_hosts and rh == gh do
      r.path == g.path
    else
      _ -> false
    end
  end

  defp redirect_uris(uris) when is_list(uris) and uris != [] do
    if Enum.all?(
         uris,
         &(is_binary(&1) and
             match?({:ok, %URI{scheme: s}} when s in ["http", "https"], URI.new(&1)))
       ),
       do: {:ok, uris},
       else: {:error, :invalid_redirect_uri}
  end

  defp redirect_uris(_), do: {:error, :invalid_redirect_uri}

  defp pkce(challenge, verifier) when is_binary(challenge) and is_binary(verifier) do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    if byte_size(computed) == byte_size(challenge) and :crypto.hash_equals(computed, challenge),
      do: :ok,
      else: {:error, :invalid_grant}
  end

  defp pkce(_, _), do: {:error, :invalid_grant}

  ## Issuing

  defp issue(entry, config, now) do
    key = Keys.current!(config.key_dir)
    ttl = config.access_token_ttl_s

    claims = %{
      "iss" => issuer(config),
      "sub" => entry.sub,
      "aud" => config.resource,
      "client_id" => entry.client_id,
      "scope" => Enum.join(entry.scope, " "),
      "iat" => now,
      "exp" => now + ttl,
      "jti" => random(),
      "profile" => "personal"
    }

    {_, token} =
      key.jwk
      |> JOSE.JWS.sign(Jason.encode!(claims), %{
        "alg" => "ES256",
        "kid" => key.kid,
        "typ" => "at+jwt"
      })
      |> JOSE.JWS.compact()

    %{
      "access_token" => token,
      "token_type" => "Bearer",
      "expires_in" => ttl,
      "scope" => claims["scope"]
    }
  end

  ## Helpers

  defp redirect(uri, params) do
    query =
      params
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    parsed = URI.parse(uri)
    existing = if parsed.query, do: URI.decode_query(parsed.query), else: %{}
    %{parsed | query: URI.encode_query(Map.merge(existing, query))} |> URI.to_string()
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp expire(state, now) do
    %{
      state
      | requests: Map.filter(state.requests, fn {_, r} -> r.exp > now end),
        codes: Map.filter(state.codes, fn {_, c} -> c.exp > now end)
    }
  end

  defp clients_path(%Config{key_dir: dir}), do: Path.join(dir, "mcp-as-clients.json")

  # sobelow_skip reason: Traversal.FileModule: the path is the key directory's plus a constant name, never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  defp load_clients(config) do
    case File.read(clients_path(config)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = clients} -> clients
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the path is the key directory's plus a constant name, never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  defp save_clients(%{config: config, clients: clients}) do
    path = clients_path(config)
    File.write!(path, Jason.encode!(clients))
    File.chmod!(path, 0o600)
  end
end
