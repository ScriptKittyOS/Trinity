# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client.Transport.HTTP do
  @moduledoc """
  The Streamable HTTP transport at 2026-07-28 (slice 060): one POST per request, the answer
  in the response body, no session, the headers `Trinity.MCP.Client.Wire.headers/2` derives
  from the request beside it. A struct, not a process: nothing is held between requests, so
  any process may send one. The bearer, when `Trinity.MCP.Client.Auth` has one, goes in
  `Authorization`; a `401` is reported with its `WWW-Authenticate` challenge and no flow of
  the driver's own follows (slice 062 owns that). Redirects are not followed and nothing is
  retried: a request that did not get its answer is an error the caller reads.
  """
  @behaviour Trinity.MCP.Client.Transport

  alias Trinity.MCP.Client.{Auth, Wire}
  alias Trinity.MCP.ServerConfig

  @default_timeout 30_000

  defstruct [:url, :name, :bearer, :req_options]

  @type t :: %__MODULE__{
          url: String.t(),
          name: String.t(),
          bearer: String.t() | nil,
          req_options: keyword()
        }

  @impl true
  def connect(%ServerConfig{transport: "http", url: url, name: name} = config, _owner, opts) do
    {:ok,
     %__MODULE__{
       url: url,
       name: name,
       bearer: Auth.bearer(config),
       req_options: Keyword.get(opts, :req_options, [])
     }}
  end

  @impl true
  def request(%__MODULE__{} = t, request, opts), do: post(t, request, opts, :answer)

  @impl true
  def notify(%__MODULE__{} = t, request, opts) do
    with {:ok, _} <- post(t, request, opts, :none), do: :ok
  end

  @impl true
  def close(_t), do: :ok

  defp post(t, request, opts, expect) do
    headers =
      [{"content-type", "application/json"}, {"accept", "application/json"}] ++
        Wire.headers(request, Keyword.get(opts, :schemas, %{})) ++ bearer(t.bearer)

    options =
      Keyword.merge(
        [
          headers: headers,
          body: Wire.encode(request),
          receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
          retry: false,
          redirect: false,
          decode_body: false
        ],
        t.req_options
      )

    case Req.post(t.url, options) do
      {:ok, %Req.Response{status: 200, body: body}} when expect == :answer ->
        Wire.decode(body)

      {:ok, %Req.Response{status: status}} when status in [200, 202, 204] and expect == :none ->
        {:ok, nil}

      {:ok, %Req.Response{status: 401} = r} ->
        {:error, {:unauthorized, Req.Response.get_header(r, "www-authenticate")}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, refusal(body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp bearer(nil), do: []
  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  # The transport's refusal, when it is a JSON-RPC error, decoded through the core; the raw
  # body's first bytes otherwise.
  defp refusal(body) when is_binary(body) do
    case Wire.decode(body) do
      {:ok, %{"error" => error}} -> error
      _ -> binary_part(body, 0, min(byte_size(body), 200))
    end
  end

  defp refusal(other), do: other
end
