# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Client do
  @moduledoc """
  The Mattermost REST calls the adapter makes (slice 072), and nothing else.

  **The token.** Each call reads it through `Trinity.Config.secret/1` and hands it to the request
  as a bearer credential; it is never stored, returned, or put in an error. An error says which
  call failed and how (`{:http, status, server_error_id}`, `{:transport, reason}`), never with the
  request attached, because a request carries its headers and a header is where the token is.
  A raise inside the HTTP client is caught for the same reason: its message or its arguments could
  carry the request.
  """

  alias Trinity.Gateways.Mattermost.State

  @receive_timeout 15_000

  @typedoc "Why a call failed, with nothing in it that came from the request."
  @type error ::
          {:missing_secret, String.t()}
          | {:http, pos_integer(), String.t() | nil}
          | {:transport, atom() | String.t()}
          | :not_running

  @doc "The bot's own user."
  @spec me() :: {:ok, map()} | {:error, error()}
  def me, do: request(:get, "/api/v4/users/me")

  @doc "The client configuration, the old format, which is where `MaxPostSize` is."
  @spec client_config() :: {:ok, map()} | {:error, error()}
  def client_config, do: request(:get, "/api/v4/config/client", params: [format: "old"])

  @doc "Creates a post."
  @spec create_post(map()) :: {:ok, map()} | {:error, error()}
  def create_post(body), do: request(:post, "/api/v4/posts", json: body)

  @doc "Patches a post the bot made (its message). The id must already have been checked."
  @spec patch_post(String.t(), map()) :: {:ok, map()} | {:error, error()}
  def patch_post(post_id, body), do: request(:put, "/api/v4/posts/#{post_id}/patch", json: body)

  @doc "Opens an interactive dialog for the person who pressed a button (`trigger_id`)."
  @spec open_dialog(map()) :: {:ok, map()} | {:error, error()}
  def open_dialog(body), do: request(:post, "/api/v4/actions/dialogs/open", json: body)

  @doc "Shows the bot as typing in a channel, or a thread in it."
  @spec typing(String.t(), String.t() | nil) :: {:ok, map()} | {:error, error()}
  def typing(channel_id, root_id) do
    request(:post, "/api/v4/users/me/typing",
      json: %{"channel_id" => channel_id, "parent_id" => root_id || ""}
    )
  end

  @doc "The token, read now and from nowhere else. Public so the socket uses the same read."
  @spec token() :: {:ok, String.t()} | {:error, error()}
  def token do
    case State.options() do
      nil -> {:error, :not_running}
      options -> Trinity.Config.secret(options.token_env)
    end
  end

  defp request(method, path, opts \\ []) do
    with {:ok, token} <- token() do
      State.options()
      |> base(token)
      |> Req.request([method: method, url: path] ++ opts)
      |> answer()
    end
  rescue
    error -> {:error, {:transport, error.__struct__ |> Module.split() |> Enum.join(".")}}
  end

  defp base(options, token) do
    Req.new(
      base_url: options.url,
      auth: {:bearer, token},
      retry: false,
      receive_timeout: @receive_timeout,
      connect_options: connect_options(options)
    )
  end

  defp connect_options(%{cacertfile: path}) when is_binary(path),
    do: [transport_opts: [cacertfile: path]]

  defp connect_options(_options), do: []

  defp answer({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, if(is_map(body), do: body, else: %{})}

  defp answer({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http, status, server_error_id(body)}}

  defp answer({:error, %{reason: reason}}) when is_atom(reason),
    do: {:error, {:transport, reason}}

  defp answer({:error, exception}),
    do: {:error, {:transport, exception.__struct__ |> Module.split() |> Enum.join(".")}}

  # The server's error id (`api.context.session_expired.app_error`) names the failure without
  # repeating anything sent; its `message` can quote the request, so it is not kept.
  defp server_error_id(%{"id" => id}) when is_binary(id), do: id
  defp server_error_id(_body), do: nil
end
