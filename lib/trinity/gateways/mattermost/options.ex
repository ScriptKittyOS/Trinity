# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Options do
  @moduledoc """
  The Mattermost adapter's options (slice 072). The schema is the documentation (docs/03).

  None of them is a secret. The bot token and the slash command's token are named here by the
  environment variable that holds them, and read through `Trinity.Config.secret/1` when used.
  """

  @schema [
    url: [
      type: {:or, [{:custom, __MODULE__, :http_url, []}, nil]},
      default: nil,
      doc:
        "The server's base URL, as a browser would open it (`https://chat.example.org`). The " <>
          "WebSocket is derived from it (`wss://…/api/v4/websocket`). Unset, the adapter is idle."
    ],
    token_env: [
      type: :string,
      default: "MATTERMOST_BOT_TOKEN",
      doc: "The environment variable holding the bot account's access token."
    ],
    command_token_env: [
      type: :string,
      default: "MATTERMOST_COMMAND_TOKEN",
      doc:
        "The environment variable holding the token the server sends with the `/trinity` " <>
          "slash command. Unset, the command callback refuses every request."
    ],
    callback_url: [
      type: {:or, [{:custom, __MODULE__, :http_url, []}, nil]},
      default: nil,
      doc:
        "The base URL at which the server reaches Trinity, for the approval dialog. Unset, " <>
          "approvals are rendered as text and the capabilities say `buttons: false`."
    ],
    cacertfile: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "A CA bundle to verify the server against, for a server on a private PKI."
    ],
    backoff_ms: [
      type: :pos_integer,
      default: 1_000,
      doc: "The first reconnect delay; it doubles to `max_backoff_ms`."
    ],
    max_backoff_ms: [type: :pos_integer, default: 30_000, doc: "The longest reconnect delay."]
  ]

  @doc "Validates the options, raising `NimbleOptions.ValidationError` on a bad one."
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    opts
    |> NimbleOptions.validate!(@schema)
    |> Keyword.update!(:url, &trim/1)
    |> Keyword.update!(:callback_url, &trim/1)
  end

  defp trim(nil), do: nil
  defp trim(url), do: String.trim_trailing(url, "/")

  @doc false
  @spec http_url(term()) :: {:ok, String.t()} | {:error, String.t()}
  def http_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, value}

      _ ->
        {:error, "expected an http or https URL with a host, got: #{inspect(value)}"}
    end
  end

  def http_url(value), do: {:error, "expected an http or https URL, got: #{inspect(value)}"}

  @doc "The schema's documentation, for the moduledoc of anything that takes these options."
  @spec docs() :: String.t()
  def docs, do: NimbleOptions.docs(@schema)
end
