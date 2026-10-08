# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Plugs.HostAllowList do
  @moduledoc """
  Answers `403` to a request whose `Host` is not this machine's own (slice 136, AC5).

  Neither Phoenix nor Bandit checks the Host header. Without a check, a page on any site can point
  a name it controls at `127.0.0.1` (DNS rebinding) and then read Trinity's pages from the
  browser of the person running it, because to the browser that is the attacker's own origin. A
  loopback bind does not help: the browser making the request is on the loopback.

  The allowed names are the loopback names (`localhost`, `127.0.0.1`, `::1` written with or
  without brackets), the endpoint's configured host (`PHX_HOST` in a release), and
  `config :trinity, :web_auth, extra_hosts:`. Compared without the port, case-insensitively, and
  with a trailing dot removed.

  First in the endpoint, ahead of the static files, the MCP server and the router, so a refused
  request has been routed nowhere. The websocket transports are dispatched by Phoenix ahead of
  every plug in the endpoint, so they never reach this check; the origin list
  (`check_origin`, AC6) is what refuses a foreign page there.

  The list is read on every request rather than in `init/1`, which the release runs at compile
  time (slice 062 NOTES, F5).
  """
  @behaviour Plug

  import Plug.Conn

  @loopback ["localhost", "127.0.0.1", "::1"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if allowed?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "host not allowed\n")
      |> halt()
    end
  end

  @doc "True when `host` is one this node answers to."
  @spec allowed?(String.t() | nil) :: boolean()
  def allowed?(host) when is_binary(host), do: normalize(host) in allowed_hosts()
  def allowed?(_), do: false

  @doc "The names this node answers to, normalised."
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts do
    configured = TrinityWeb.Endpoint.config(:url)[:host]
    extra = Keyword.get(Trinity.WebAuth.config(), :extra_hosts, [])

    [configured | extra]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
    |> Enum.concat(@loopback)
    |> Enum.uniq()
  end

  defp normalize(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end
end
