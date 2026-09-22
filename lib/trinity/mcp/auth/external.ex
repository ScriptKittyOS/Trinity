# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.External do
  @moduledoc """
  The production profile (slice 062): Trinity as an OAuth 2.1 resource server against an
  external authorization server. A bearer is a JWT the issuer signed (`Token.verify/3`: the
  named checks, audience-bound to this server's resource identifier), or, with
  `introspection: true`, an opaque token asked about at the issuer's RFC 7662 endpoint
  (`active`, then the same claim checks on what it answers). Trinity issues nothing here; the
  metadata it publishes (RFC 9728) names the external issuer as the authorization server.
  """
  @behaviour Trinity.MCP.Auth

  alias Trinity.MCP.Auth
  alias Trinity.MCP.Auth.{Config, Discovery, Principal, Token}

  @impl true
  def authorize(conn, %Config{introspection: false} = config) do
    with {:ok, token} <- Auth.bearer(conn), do: Token.verify(token, config)
  end

  def authorize(conn, %Config{introspection: true} = config) do
    with {:ok, token} <- Auth.bearer(conn), do: introspect(token, config)
  end

  @impl true
  def resource_metadata(%Config{resource: resource, issuer: issuer}) do
    %{
      "resource" => resource,
      "authorization_servers" => [issuer],
      "bearer_methods_supported" => ["header"],
      "scopes_supported" => Trinity.MCP.Auth.Scopes.known()
    }
  end

  # RFC 7662: the issuer's introspection endpoint from its metadata, the token posted with the
  # resource server's own credentials when it has them, and the answer's claims checked as a
  # JWT's would be (`active` first).
  defp introspect(token, %Config{} = config) do
    with {:ok, meta} <- Discovery.authorization_server(config.issuer),
         {:ok, endpoint} <- endpoint(meta),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.post(endpoint,
             form: [token: token, token_type_hint: "access_token"],
             auth: basic(config.introspection_credentials),
             retry: false,
             decode_body: false
           ),
         {:ok, %{"active" => true} = claims} <- Jason.decode(body),
         :ok <- Token.check(claims, config, System.os_time(:second)) do
      {:ok, Principal.from_claims(claims, :production)}
    else
      {:ok, %{"active" => false}} -> {:error, :inactive}
      {:ok, %Req.Response{status: status}} -> {:error, {:introspection_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :introspection_failed}
    end
  end

  defp endpoint(%{"introspection_endpoint" => e}) when is_binary(e), do: {:ok, e}
  defp endpoint(_), do: {:error, :no_introspection_endpoint}

  defp basic(nil), do: nil
  defp basic({id, secret}), do: {:basic, id <> ":" <> secret}
end
