# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.HostAndOriginTest do
  @moduledoc """
  Slice 136 AC5 and AC6, over a real socket to the suite's running endpoint.

  AC5: a request whose `Host` is not this machine's own is `403` before routing, on a page, on a
  path no route matches and on a static file alike; the loopback names and the configured host
  pass. AC6: the websocket origin list is explicit in every environment, and a websocket upgrade
  from a foreign page is refused.

  The suite binds `127.0.0.1` in `:none`, which is the desktop's shape: no login, the Host
  allow-list and the origin list are all there is.
  """
  use TrinityWeb.ConnCase

  @moduletag :capture_log

  alias TrinityWeb.RawHTTP

  describe "AC5: the Host allow-list" do
    test "a foreign Host is 403 before routing, wherever it points" do
      for path <- ["/", "/permissions", "/no-such-route", "/assets/css/app.css", "/oauth/token"] do
        {status, _headers, body} = RawHTTP.request("GET", path, [{"host", "evil.example"}])

        assert status == 403,
               "GET #{path} with Host: evil.example answered #{status}; a rebinding page reads it"

        assert body =~ "host not allowed"
      end

      # The same with a port, and a POST: the port is not part of the decision and the method is
      # not either.
      assert {403, _, _} =
               RawHTTP.request("POST", "/auth/token", [
                 {"host", "evil.example:#{RawHTTP.port()}"},
                 {"content-length", "0"}
               ])
    end

    test "the loopback names and the configured host pass" do
      port = RawHTTP.port()

      for host <- [
            "localhost",
            "127.0.0.1",
            "[::1]",
            "LOCALHOST",
            "localhost.",
            "www.example.com"
          ] do
        {status, _headers, _body} =
          RawHTTP.request("GET", "/permissions", [{"host", "#{host}:#{port}"}])

        assert status == 200, "Host: #{host} was refused (#{status})"
      end
    end

    test "the configured host is the endpoint's own url host" do
      assert TrinityWeb.Endpoint.config(:url)[:host] in TrinityWeb.Plugs.HostAllowList.allowed_hosts()
      refute TrinityWeb.Plugs.HostAllowList.allowed?("evil.example")
      refute TrinityWeb.Plugs.HostAllowList.allowed?("localhost.evil.example")
      refute TrinityWeb.Plugs.HostAllowList.allowed?(nil)
    end
  end

  describe "AC6: the websocket origin" do
    defp upgrade(origin) do
      headers =
        [
          {"host", "127.0.0.1:#{RawHTTP.port()}"},
          {"upgrade", "websocket"},
          {"connection", "Upgrade"},
          {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))},
          {"sec-websocket-version", "13"}
        ] ++ if(origin, do: [{"origin", origin}], else: [])

      {status, _headers, _body} =
        RawHTTP.request("GET", "/live/websocket?vsn=2.0.0", headers)

      status
    end

    test "a foreign Origin is refused, the machine's own is upgraded" do
      assert upgrade("http://evil.example") == 403
      assert upgrade("http://evil.example:#{RawHTTP.port()}") == 403
      assert upgrade("http://localhost.evil.example") == 403

      assert upgrade("http://127.0.0.1:#{RawHTTP.port()}") == 101
      assert upgrade("http://localhost:#{RawHTTP.port()}") == 101
    end

    test "check_origin is an explicit list in the running endpoint" do
      origins = TrinityWeb.Endpoint.config(:check_origin)
      assert is_list(origins) and origins != []
    end

    # The value each environment's configuration resolves to, read from the files themselves:
    # config/config.exs with the environment's file, and for :prod also config/runtime.exs, which
    # is where the release's list is built. `:conn` and `false` are refused everywhere.
    test "check_origin is an explicit list in dev, test and prod" do
      for env <- [:dev, :test, :prod] do
        base = Config.Reader.read!("config/config.exs", env: env, target: :host)

        runtime =
          if env == :prod,
            do: Config.Reader.read!("config/runtime.exs", env: :prod, target: :host),
            else: []

        value =
          [base, runtime]
          |> Enum.flat_map(
            &(&1
              |> Keyword.get(:trinity, [])
              |> Keyword.get_values(TrinityWeb.Endpoint))
          )
          |> Enum.reduce([], &Keyword.merge(&2, &1))
          |> Keyword.get(:check_origin, :unset)

        assert is_list(value) and value != [],
               "#{env}: check_origin is #{inspect(value)}, not an explicit list"

        refute :conn in value
      end
    end
  end
end
