# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.FakeOIDCIssuer do
  @moduledoc """
  An OpenID Connect issuer on a loopback port, in the test's own VM (slice 136, AC7 and AC8).

  It serves what a relying party reads: the discovery document, the JWKS, and the token endpoint.
  Its key is an ES256 key generated when it starts; nothing is fixed in the tree. There is no
  authorization endpoint page: a test reads the authorization request from the redirect Trinity
  sends and calls `issue_code/2` as the issuer would after the user signed in, choosing the claims.

  The token endpoint checks what an issuer checks and nothing more: the code exists and is used
  once, the redirect URI matches the one the code was issued for, and the PKCE verifier hashes to
  the stored challenge (S256). The ID token carries the nonce of the authorization request unless
  the test asks otherwise, so a test can show the relying party refusing a wrong one.

  Options at `start/1`: `code_challenge_methods: ["S256"]` (what discovery advertises),
  `iss_parameter: true` (RFC 9207 advertised).
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  @doc "Starts the issuer; returns `%{url: issuer_url, state: agent}`. Stopped with the test."
  @spec start(keyword()) :: %{url: String.t(), state: pid()}
  def start(opts \\ []) do
    jwk =
      JOSE.JWK.generate_key({:ec, "P-256"}) |> JOSE.JWK.merge(%{"kid" => "k1", "use" => "sig"})

    {:ok, agent} =
      Agent.start_link(fn -> %{jwk: jwk, codes: %{}, opts: opts, url: nil, token_calls: 0} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    Agent.update(agent, &Map.put(&1, :url, url))

    ExUnit.Callbacks.on_exit(fn ->
      for pid <- [server, agent], Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    %{url: url, state: agent, server: server}
  end

  @doc """
  What the issuer does once the user has signed in: a code bound to the authorization request's
  `nonce`, `code_challenge` and `redirect_uri`, which `/token` will exchange for an ID token with
  `claims` (merged over `sub`, `iss`, `aud`, `exp`, `iat` and `nonce`).
  """
  @spec issue_code(%{state: pid()}, map(), map()) :: String.t()
  def issue_code(%{state: agent}, request, claims) do
    code = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    Agent.update(agent, fn s ->
      put_in(s, [:codes, code], %{request: request, claims: claims})
    end)

    code
  end

  @doc "How many requests the token endpoint has had, refused ones included."
  @spec token_calls(%{state: pid()}) :: non_neg_integer()
  def token_calls(%{state: agent}), do: Agent.get(agent, & &1.token_calls)

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent), do: conn |> put_private(:issuer, agent) |> super([])

  get "/.well-known/openid-configuration" do
    s = Agent.get(conn.private.issuer, & &1)

    doc =
      %{
        "issuer" => s.url,
        "authorization_endpoint" => s.url <> "/authorize",
        "token_endpoint" => s.url <> "/token",
        "jwks_uri" => s.url <> "/jwks",
        "response_types_supported" => ["code"],
        "scopes_supported" => ["openid", "profile"],
        "subject_types_supported" => ["public"],
        "id_token_signing_alg_values_supported" => ["ES256"],
        "token_endpoint_auth_methods_supported" => ["client_secret_basic", "client_secret_post"],
        "code_challenge_methods_supported" =>
          Keyword.get(s.opts, :code_challenge_methods, ["S256"]),
        "authorization_response_iss_parameter_supported" =>
          Keyword.get(s.opts, :iss_parameter, true)
      }

    json(conn, 200, doc)
  end

  get "/jwks" do
    jwk = Agent.get(conn.private.issuer, & &1.jwk)
    {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    json(conn, 200, %{"keys" => [public]})
  end

  post "/token" do
    agent = conn.private.issuer
    Agent.update(agent, &Map.update!(&1, :token_calls, fn n -> n + 1 end))
    params = conn.body_params
    code = params["code"]

    entry =
      Agent.get_and_update(agent, fn s ->
        {get_in(s, [:codes, code]), update_in(s, [:codes], &Map.delete(&1, code))}
      end)

    with %{request: request, claims: claims} <- entry,
         true <- params["redirect_uri"] == request["redirect_uri"],
         true <- s256(params["code_verifier"]) == request["code_challenge"] do
      s = Agent.get(agent, & &1)
      now = System.system_time(:second)

      base = %{
        "iss" => s.url,
        "sub" => "user-1",
        "aud" => request["client_id"],
        "iat" => now,
        "exp" => now + 300,
        "nonce" => request["nonce"]
      }

      id_token = sign(s.jwk, Map.merge(base, claims))

      json(conn, 200, %{
        "access_token" => "at-" <> code,
        "token_type" => "Bearer",
        "expires_in" => 300,
        "id_token" => id_token
      })
    else
      _ -> json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp s256(nil), do: nil
  defp s256(verifier), do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp sign(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "k1"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
