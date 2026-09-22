# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Discovery do
  @moduledoc """
  Finding an authorization server's metadata (slice 062): RFC 8414 (`/.well-known/oauth-authorization-server`,
  the well-known segment inserted before the issuer's path when it has one) first, OpenID
  Connect discovery (`/.well-known/openid-configuration`) second. The document's `issuer` must
  equal the issuer asked for (RFC 8414 section 3.3), or the document is refused: a server
  answering for another issuer is the substitution the check exists to catch. Also the RFC
  9728 Protected Resource Metadata a resource server publishes, fetched the same way from a
  `resource_metadata` URL a `401` names.
  """

  @type metadata :: %{required(String.t()) => term()}

  @doc "The authorization server's metadata for an issuer."
  @spec authorization_server(String.t(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def authorization_server(issuer, opts \\ []) when is_binary(issuer) do
    urls(issuer)
    |> Enum.reduce_while({:error, :not_found}, fn url, _ ->
      case fetch_json(url, opts) do
        {:ok, %{"issuer" => ^issuer} = doc} -> {:halt, {:ok, doc}}
        {:ok, %{"issuer" => other}} -> {:halt, {:error, {:issuer_mismatch, other}}}
        {:ok, _} -> {:cont, {:error, :no_issuer_in_document}}
        {:error, {:status, 404}} -> {:cont, {:error, :not_found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "The two well-known URLs for an issuer, in the order tried."
  @spec urls(String.t()) :: [String.t()]
  def urls(issuer) do
    uri = URI.parse(issuer)
    path = String.trim_trailing(uri.path || "", "/")
    base = %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string()

    [
      base <> "/.well-known/oauth-authorization-server" <> path,
      base <> path <> "/.well-known/openid-configuration"
    ]
  end

  @doc "A Protected Resource Metadata document from its URL."
  @spec protected_resource(String.t(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def protected_resource(url, opts \\ []) when is_binary(url) do
    case fetch_json(url, opts) do
      {:ok, %{"resource" => _} = doc} -> {:ok, doc}
      {:ok, _} -> {:error, :no_resource_in_document}
      {:error, _} = error -> error
    end
  end

  @doc "A JSON document from a URL, with the request options the host passes (`req_options:`)."
  @spec fetch_json(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_json(url, opts \\ []) do
    options =
      Keyword.merge(
        [receive_timeout: 10_000, retry: false, redirect: false, decode_body: false],
        Keyword.get(opts, :req_options, [])
      )

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{} = doc} -> {:ok, doc}
          _ -> {:error, :not_json}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
