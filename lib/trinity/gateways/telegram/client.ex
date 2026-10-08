# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Client do
  @moduledoc """
  The Telegram Bot API, over `Req` (slice 071). No Telegram library: NOTES records the measurement
  that decided it (the one candidate that can be pinned keeps its polling offset in memory and
  hard-codes its file host, and the other cannot be pinned at all).

  **The token.** It is read from `TELEGRAM_BOT_TOKEN` through `Trinity.Config.secret/1` at every
  call, as a provider key is, and never held in a process's state. The Bot API puts it in the URL
  path (`/bot<token>/<method>`), which is where a token leaks from: a transport error that prints
  its request, a log line that prints a URL. So nothing this module returns or logs is built from
  the URL or from an exception's message: a failure is `{:error, {:telegram, code, description}}`
  (Telegram's own words, which do not echo the token), `{:error, {:transport, reason}}` with the
  transport's reason atom, or `{:error, {:http, status}}`. Req's retry step is off, because it logs;
  the poller has its own backoff.

  **The host.** `config :trinity, :telegram, base_url:` (default `https://api.telegram.org`), so
  the suite talks to a fake Bot API on a loopback port and never to the network.
  """

  @default_base_url "https://api.telegram.org"
  @token_env "TELEGRAM_BOT_TOKEN"
  @call_timeout_ms 15_000

  @typedoc "Why a call did not succeed. None of these carries the token or a URL."
  @type error ::
          {:missing_secret, String.t()}
          | {:telegram, integer(), String.t()}
          | {:transport, atom() | String.t()}
          | {:http, integer()}
          | {:too_large, non_neg_integer()}

  @doc "The environment variable the token is read from."
  @spec token_env() :: String.t()
  def token_env, do: @token_env

  @doc "Whether a token is configured, without reading it into anything that outlives the call."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, Trinity.Config.secret(@token_env))

  @doc "The Bot API host in force."
  @spec base_url() :: String.t()
  def base_url,
    do:
      :trinity |> Application.get_env(:telegram, []) |> Keyword.get(:base_url, @default_base_url)

  @doc """
  Calls a Bot API method with JSON parameters and answers its `result`. `:receive_timeout` in
  `opts` lengthens the wait, which a long poll needs.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, term()} | {:error, error()}
  def call(method, params \\ %{}, opts \\ []) when is_binary(method) and is_map(params) do
    with {:ok, token} <- Trinity.Config.secret(@token_env) do
      [
        method: :post,
        url: base_url() <> "/bot" <> token <> "/" <> method,
        json: params,
        receive_timeout: Keyword.get(opts, :receive_timeout, @call_timeout_ms),
        retry: false
      ]
      |> Req.new()
      |> Req.request()
      |> answer()
    end
  end

  @doc """
  Downloads a file `getFile` named, refusing one larger than `max_bytes` (by the size Telegram
  reported and again by the bytes that arrived).
  """
  @spec download(String.t(), pos_integer()) :: {:ok, binary()} | {:error, error()}
  def download(file_path, max_bytes) when is_binary(file_path) do
    with {:ok, token} <- Trinity.Config.secret(@token_env) do
      [
        method: :get,
        url: base_url() <> "/file/bot" <> token <> "/" <> file_path,
        receive_timeout: @call_timeout_ms,
        retry: false,
        decode_body: false
      ]
      |> Req.new()
      |> Req.request()
      |> case do
        {:ok, %Req.Response{status: 200, body: body}} when byte_size(body) <= max_bytes ->
          {:ok, body}

        {:ok, %Req.Response{status: 200, body: body}} ->
          {:error, {:too_large, byte_size(body)}}

        other ->
          answer(other)
      end
    end
  end

  defp answer({:ok, %Req.Response{body: %{"ok" => true, "result" => result}}}), do: {:ok, result}

  defp answer({:ok, %Req.Response{body: %{"ok" => false} = body}}) do
    {:error,
     {:telegram, Map.get(body, "error_code", 0), Map.get(body, "description", "no description")}}
  end

  defp answer({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}

  # The reason atom only: an exception's message may be built from the request, and the request
  # carries the token in its path.
  defp answer({:error, %{reason: reason}}) when is_atom(reason),
    do: {:error, {:transport, reason}}

  defp answer({:error, %{__struct__: struct}}),
    do: {:error, {:transport, struct |> Module.split() |> Enum.join(".")}}
end
