# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.FakeAS do
  @moduledoc """
  A fake enterprise authorization server (slice 062): RFC 8414 metadata, an authorization endpoint
  that consents on its own (redirecting with `code`, `state` and `iss`), a token endpoint with
  PKCE (S256) and RFC 8707 `resource`, a JWKS, RFC 7662 introspection, RFC 7591 registration,
  and a control surface a test drives: `mint/2` (a token with whatever claims, for the resource
  server's refusals), `rotate/1` (a new signing key; the old ones stay in the JWKS), `forget_old/1`
  (the old keys dropped from the JWKS, so a token they signed becomes unverifiable). One instance
  per test, behind Bandit on a loopback port; `issuer/1` is its URL.
  """
  use Agent

  @behaviour Plug

  import Plug.Conn

  def start!(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{keys: [new_key()], codes: %{}, clients: %{}, path: Keyword.get(opts, :path, "")}
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://127.0.0.1:#{port}" <> Map.get(Agent.get(agent, & &1), :path)
    Agent.update(agent, &Map.put(&1, :issuer, issuer))

    ExUnit.Callbacks.on_exit(fn ->
      try do
        GenServer.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    %{agent: agent, issuer: issuer, server: server}
  end

  @doc "A token this AS signs, with the claims given over the defaults (sub, aud, scope, exp)."
  def mint(%{agent: agent, issuer: issuer}, claims) when is_map(claims) do
    now = System.os_time(:second)
    key = current_key(agent)

    base = %{
      "iss" => issuer,
      "sub" => "u@example.com",
      "aud" => "http://resource.example/mcp",
      "scope" => "trinity:tools:read",
      "iat" => now,
      "exp" => now + 300,
      "jti" => random(),
      "client_id" => "test-client"
    }

    sign(key, Map.merge(base, claims))
  end

  @doc "A token signed with an unrelated key (the JWKS never held it)."
  def mint_foreign(%{issuer: issuer}, claims \\ %{}) do
    now = System.os_time(:second)

    base = %{
      "iss" => issuer,
      "sub" => "x",
      "aud" => "http://resource.example/mcp",
      "exp" => now + 300
    }

    sign(new_key(), Map.merge(base, claims))
  end

  @doc "Rotates the signing key; the old ones stay published."
  def rotate(%{agent: agent}) do
    Agent.update(agent, fn s -> %{s | keys: [new_key() | s.keys]} end)
    current_key(agent).kid
  end

  @doc "Drops every key but the current one from the JWKS."
  def forget_old(%{agent: agent}), do: Agent.update(agent, fn s -> %{s | keys: [hd(s.keys)]} end)

  @doc "The current signing key's kid."
  def kid(%{agent: agent}), do: current_key(agent).kid

  @doc "How many times the JWKS was fetched."
  def jwks_fetches(%{agent: agent}), do: Agent.get(agent, &Map.get(&1, :jwks_fetches, 0))

  ## The Plug

  @impl true
  def init(agent), do: agent

  @impl true
  def call(conn, agent) do
    state = Agent.get(agent, & &1)
    path = String.replace_prefix(conn.request_path, state.path, "")
    route(conn.method, path, conn, agent, state)
  end

  defp route("GET", "/.well-known/oauth-authorization-server" <> _, conn, _agent, state),
    do: json(conn, 200, metadata(state))

  defp route("GET", "/jwks", conn, agent, state) do
    Agent.update(agent, &Map.update(&1, :jwks_fetches, 1, fn n -> n + 1 end))
    json(conn, 200, %{"keys" => Enum.map(state.keys, &public_jwk/1)})
  end

  defp route("GET", "/authorize", conn, agent, state), do: authorize(conn, agent, state)
  defp route("POST", "/token", conn, agent, state), do: token(conn, agent, state)
  defp route("POST", "/introspect", conn, _agent, state), do: introspect(conn, state)
  defp route("POST", "/register", conn, agent, _state), do: register(conn, agent)

  # A Client ID Metadata Document a test client publishes (the personal profile's CIMD path).
  defp route("GET", "/client.json", conn, _agent, state) do
    json(conn, 200, %{
      "client_id" => state.issuer <> "/client.json",
      "client_name" => "Fake CIMD client",
      "redirect_uris" => ["http://127.0.0.1/callback"],
      "token_endpoint_auth_method" => "none"
    })
  end

  defp route(_method, _path, conn, _agent, _state), do: send_resp(conn, 404, "")

  defp metadata(state) do
    iss = state.issuer

    %{
      "issuer" => iss,
      "authorization_endpoint" => iss <> "/authorize",
      "token_endpoint" => iss <> "/token",
      "jwks_uri" => iss <> "/jwks",
      "introspection_endpoint" => iss <> "/introspect",
      "registration_endpoint" => iss <> "/register",
      "response_types_supported" => ["code"],
      "code_challenge_methods_supported" => ["S256"],
      "authorization_response_iss_parameter_supported" => true
    }
  end

  # Consents on its own: the code remembers the challenge, the resource and the client.
  defp authorize(conn, agent, state) do
    conn = fetch_query_params(conn)
    p = conn.query_params
    code = random()

    Agent.update(agent, fn s ->
      put_in(s.codes[code], %{
        challenge: p["code_challenge"],
        resource: p["resource"],
        client_id: p["client_id"],
        redirect_uri: p["redirect_uri"],
        scope: p["scope"] || "trinity:tools:read"
      })
    end)

    query = URI.encode_query(%{"code" => code, "state" => p["state"], "iss" => state.issuer})
    sep = if String.contains?(p["redirect_uri"], "?"), do: "&", else: "?"

    conn
    |> put_resp_header("location", p["redirect_uri"] <> sep <> query)
    |> send_resp(302, "")
  end

  defp token(conn, agent, state) do
    {:ok, body, conn} = read_body(conn)
    p = URI.decode_query(body)

    with %{} = entry <-
           Agent.get_and_update(agent, fn s ->
             {s.codes[p["code"]], %{s | codes: Map.delete(s.codes, p["code"])}}
           end),
         true <- pkce_ok?(entry.challenge, p["code_verifier"]),
         true <- entry.resource == p["resource"] do
      now = System.os_time(:second)

      claims = %{
        "iss" => state.issuer,
        "sub" => "u@example.com",
        "aud" => entry.resource,
        "scope" => entry.scope,
        "client_id" => entry.client_id,
        "iat" => now,
        "exp" => now + 300,
        "jti" => random()
      }

      json(conn, 200, %{
        "access_token" => sign(hd(state.keys), claims),
        "token_type" => "Bearer",
        "expires_in" => 300,
        "scope" => entry.scope
      })
    else
      _ -> json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  defp introspect(conn, state) do
    {:ok, body, conn} = read_body(conn)
    p = URI.decode_query(body)

    case verify(state.keys, p["token"]) do
      {:ok, claims} ->
        json(conn, 200, Map.put(claims, "active", claims["exp"] > System.os_time(:second)))

      :error ->
        json(conn, 200, %{"active" => false})
    end
  end

  defp register(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    meta = Jason.decode!(body)
    id = "dcr-" <> random()
    Agent.update(agent, fn s -> put_in(s.clients[id], meta) end)
    json(conn, 201, Map.put(meta, "client_id", id))
  end

  ## Keys and tokens

  defp new_key do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    %{jwk: jwk, kid: jwk |> JOSE.JWK.thumbprint() |> binary_part(0, 10)}
  end

  defp current_key(agent), do: Agent.get(agent, &hd(&1.keys))

  defp public_jwk(%{jwk: jwk, kid: kid}) do
    {_, m} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.merge(m, %{"kid" => kid, "use" => "sig", "alg" => "ES256"})
  end

  defp sign(%{jwk: jwk, kid: kid}, claims) do
    {_, token} =
      jwk
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "ES256", "kid" => kid})
      |> JOSE.JWS.compact()

    token
  end

  defp verify(keys, token) when is_binary(token) do
    Enum.find_value(keys, :error, fn %{jwk: jwk} ->
      case JOSE.JWS.verify_strict(jwk, ["ES256"], token) do
        {true, payload, _} -> {:ok, Jason.decode!(payload)}
        _ -> nil
      end
    end)
  rescue
    _ -> :error
  end

  defp verify(_, _), do: :error

  defp pkce_ok?(challenge, verifier) when is_binary(challenge) and is_binary(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false) == challenge

  defp pkce_ok?(_, _), do: false

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
