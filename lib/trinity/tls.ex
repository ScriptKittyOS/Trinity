# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TLS do
  @moduledoc """
  Keeps every outbound TLS client off TLS 1.3 on an OTP that carries CVE-2026-89422
  (ADR-0014).

  The advisory (GHSA-rgxr-4g4w-j875): OTP's TLS 1.3 client completes a handshake without
  checking the server's certificate when the ServerHello carries a `pre_shared_key` the client
  never offered, so anyone on the path can impersonate a model provider or an MCP server. Its
  workaround is `{versions, ['tlsv1.2']}`, and it says no configuration keeps TLS 1.3 and
  mitigates the issue. The fix is in OTP 28.5.0.7. The container images build that from
  source; the desktop runs the ERTS Burrito downloads, which did not exist for 28.5.0.7 on Linux
  or macOS when this was written, so the desktop runs 28.5.0.6 with this clamp.

  ## The decision is the running runtime's

  `affected?/0` asks the `ssl` application that is loaded, which is the component the CVE is in
  and the one fact every runtime carries: an assembled release has no `OTP_VERSION` file
  (slice 130 NOTES, D-130-11). On OTP 28 the fix is `ssl` 11.6.0.6 (`otp_versions.table`,
  OTP-28.5.0.7). On a major this module has no fixed version for, it clamps. So the container on
  28.5.0.7 keeps TLS 1.3, the desktop on 28.5.0.6 clamps, and the clamp lifts itself when the
  desktop's pin moves.

  ## Three layers, because one is not enough

  `client_config/0` is what `config/runtime.exs` applies before any application starts:

    * the `ssl` application's `protocol_version`, which every client that passes no `versions`
      option inherits: `:httpc` (and so Bumblebee and Tokenizers), Postgrex, WebSockex, a bare
      `:ssl.connect/3`;
    * Req's default options, which send every Req request to `Trinity.TLS.Finch`, a Finch
      instance whose pool passes the clamp to Mint. Mint passes `versions` to `ssl` itself, read
      from `ssl:versions()`'s `available` list, which ignores the setting above, so for Req and
      Finch only the transport options work;
    * ReqLLM's Finch pool, which its streaming requests use, with the same transport options.

  `test/trinity/tls_clamp_test.exs` derives the clients from the release and checks each on the
  wire. A caller that needs transport options of its own (a private CA, say) takes them from
  `req_options/1`, which keeps the clamp; a caller that passes `connect_options` past it is
  refused by Req, which will not combine a named pool with connect options.
  """

  require Logger

  @clamp [:"tlsv1.2"]

  # The first `ssl` version with the fix, per OTP major (otp_versions.table: OTP-28.5.0.7 ships
  # ssl-11.6.0.6, OTP-28.5.0.6 ships ssl-11.6.0.5). The advisory also names 27.3.4.18 and 29.1.1;
  # their `ssl` versions are not read here, so those majors clamp.
  @fixed_ssl %{"28" => [11, 6, 0, 6]}

  @finch Trinity.TLS.Finch

  @doc "The `versions` every client is held to while `affected?/0`."
  @spec clamp() :: [:ssl.tls_version()]
  def clamp, do: @clamp

  @doc "The Finch instance Req's default options name while `affected?/0`."
  @spec finch() :: atom()
  def finch, do: @finch

  @doc """
  Whether the running `ssl` application carries CVE-2026-89422.
  The two-argument form takes the OTP major and the `ssl` version so every branch is testable.
  """
  @spec affected?() :: boolean()
  def affected?, do: affected?(System.otp_release(), ssl_version())

  @spec affected?(String.t(), String.t()) :: boolean()
  def affected?(otp_major, ssl_version) do
    with {:ok, fixed} <- Map.fetch(@fixed_ssl, otp_major),
         {:ok, running} <- parse(ssl_version) do
      running < fixed
    else
      _ -> true
    end
  end

  @doc "The loaded `ssl` application's version, as a string."
  @spec ssl_version() :: String.t()
  def ssl_version do
    _ = Application.load(:ssl)
    :ssl |> Application.spec(:vsn) |> to_string()
  end

  @doc "Mint transport options: the clamp while `affected?/0`, nothing otherwise."
  @spec transport_opts() :: keyword()
  def transport_opts, do: if(affected?(), do: [versions: @clamp], else: [])

  @doc """
  The application configuration `config/runtime.exs` applies, as `{app, key, value}`. Empty
  when the runtime is not affected, so a fixed runtime is configured exactly as before.
  """
  @spec client_config() :: [{atom(), atom(), term()}]
  def client_config, do: client_config(affected?())

  @spec client_config(boolean()) :: [{atom(), atom(), term()}]
  def client_config(false), do: []

  def client_config(true) do
    [
      {:ssl, :protocol_version, @clamp},
      {:req, :default_options, [finch: [name: @finch]]},
      {:req_llm, :finch, req_llm_finch()}
    ]
  end

  # ReqLLM's own pool configuration, read from ReqLLM so its sizes stay its own, with the
  # transport options added to every pool.
  defp req_llm_finch do
    config = ReqLLM.Application.get_finch_config()

    Keyword.update!(config, :pools, fn pools ->
      Map.new(pools, fn {key, pool} -> {key, with_clamp(pool)} end)
    end)
  end

  defp with_clamp(pool) do
    Keyword.update(pool, :conn_opts, [transport_opts: [versions: @clamp]], fn conn ->
      Keyword.update(
        conn,
        :transport_opts,
        [versions: @clamp],
        &Keyword.put(&1, :versions, @clamp)
      )
    end)
  end

  @doc """
  The child spec of `Trinity.TLS.Finch`: Req's own default pool options, plus the clamp while
  `affected?/0`. Started by `Trinity.Application` before anything that makes a request.
  """
  @spec finch_child_spec() :: Supervisor.child_spec()
  def finch_child_spec do
    pool = Req.Finch.pool_options(%{connect_options: [transport_opts: transport_opts()]})
    Finch.child_spec(name: @finch, pools: %{default: pool})
  end

  @doc """
  Req options for a caller that needs transport options of its own, such as `cacertfile`.
  The clamp is merged last so it cannot be overridden; `finch: nil` lifts the default pool, which
  Req will not combine with `connect_options`.
  """
  @spec req_options(keyword()) :: keyword()
  def req_options(transport_opts) do
    [
      finch: nil,
      connect_options: [transport_opts: Keyword.merge(transport_opts, transport_opts())]
    ]
  end

  @doc "Logs, once at boot, which way the decision went and why."
  @spec log_decision() :: :ok
  def log_decision do
    if affected?() do
      Logger.notice(
        "TLS clients held to TLS 1.2: ssl #{ssl_version()} on OTP #{System.otp_release()} " <>
          "carries CVE-2026-89422 (ADR-0014)"
      )
    end

    :ok
  end

  defp parse(version) do
    parts = String.split(version, ".")

    if parts != [] and Enum.all?(parts, &(&1 =~ ~r/^\d+$/)),
      do: {:ok, Enum.map(parts, &String.to_integer/1)},
      else: :error
  end
end
