# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.SecretsTest do
  @moduledoc """
  Slice 072, AC6: the bot token is read through `Trinity.Config.secret/1` and appears in no log
  line, on a success path and on every error path the adapter has: the server refusing the token
  at the upgrade and at the REST API, the token missing, a dialog that will not open, and the socket
  process crashing with the token in its connection.

  Every case captures at `:debug`, with the logger's own level lowered for the duration, so a
  line the adapter emits below the suite's usual level is read too. Each case also asserts that
  the path it names was taken (its own log line is there), because "nothing was logged" passes
  just as well when nothing happened. And each asserts that the redaction filter masked nothing:
  the claim is that the adapter never hands the token to the logger, not that the filter caught
  it when it did.
  """
  use Trinity.SessionCase

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Trinity.Gateways.Mattermost.TestHelpers

  alias Trinity.Gateways.{Mattermost, Router}
  alias Trinity.Gateways.Mattermost.{FakeServer, LogTap, Signing, Socket, State}
  alias Trinity.LLM.Providers.Fake

  @endpoint TrinityWeb.Endpoint

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
  end

  # What `capture_log/1` sees, and what the tap sees beside it (SASL reports included).
  defp logged(fun) do
    tap = LogTap.attach(self())
    captured = capture_log(fun)
    Process.sleep(50)
    captured <> LogTap.read(tap)
  end

  defp assert_clean(log, token) do
    refute log =~ token, "the token is in the log:\n#{log}"
    refute log =~ "[REDACTED", "the redaction filter had to mask something:\n#{log}"
  end

  test "AC6: the token is read through Trinity.Config.secret/1" do
    {env, token} = token!()
    server = FakeServer.start!(token)
    start_supervised!({Mattermost, url: server.url, token_env: env, backoff_ms: 20})
    assert Trinity.Gateways.Mattermost.Client.token() == Trinity.Config.secret(env)
    assert {:ok, ^token} = Trinity.Config.secret(env)
  end

  test "AC6, success path: a message in and a streamed reply out, and the token is in no line" do
    start_supervised!(Router)
    pair_tester!()

    tap = LogTap.attach(self())

    {server, log} =
      with_log(fn ->
        server = start_adapter!()

        Fake.scripts([
          [
            {:text_delta, "fine "},
            {:sleep, 800},
            {:text_delta, "thanks"},
            {:usage, %{input_tokens: 1, output_tokens: 1}},
            {:done, :stop}
          ]
        ])

        FakeServer.push(server, hd(FakeServer.frames("posted")))
        await_shown(server, "fine thanks")
        server
      end)

    log = log <> LogTap.read(tap)
    assert log =~ "mattermost: connected"
    assert_clean(log, server.token)
  end

  test "AC6, error path: the server refuses the token at the upgrade" do
    {env, token} = token!()
    # The server expects a different token, so the adapter's is refused everywhere.
    server = FakeServer.start!(FakeServer.random_id())

    log =
      logged(fn ->
        start_supervised!(
          {Mattermost, url: server.url, token_env: env, backoff_ms: 20, max_backoff_ms: 40}
        )

        await(
          fn -> length(FakeServer.connects(server)) >= 2 end,
          "a refused upgrade, and a retry"
        )
      end)

    assert log =~ "the server answered the upgrade with 401"
    assert_clean(log, token)
  end

  test "AC6, error path: the upgrade is accepted but the REST API refuses the token" do
    {env, token} = token!()
    server = FakeServer.start!(token)

    start_supervised!(
      {Mattermost, url: server.url, token_env: env, backoff_ms: 20, max_backoff_ms: 40}
    )

    await(fn -> State.facts() end, "the first connection")

    # The token changes under the adapter: the socket's next connection is refused by REST too.
    {_other_env, other} = token!()
    System.put_env(env, other)

    log =
      logged(fn ->
        FakeServer.drop_sockets(server)

        await(
          fn -> length(FakeServer.connects(server)) >= 3 end,
          "reconnects with the new token",
          15_000
        )
      end)

    assert log =~ "401"
    assert_clean(log, token)
    assert_clean(log, other)
  end

  test "AC6, error path: no token is set, and the variable is named, not a value" do
    env = "MATTERMOST_TEST_TOKEN_UNSET_#{System.unique_integer([:positive])}"
    System.delete_env(env)
    server = FakeServer.start!(FakeServer.random_id())

    log =
      logged(fn ->
        start_supervised!(
          {Mattermost, url: server.url, token_env: env, backoff_ms: 20, max_backoff_ms: 40}
        )

        await(fn -> length(FakeServer.connects(server)) >= 2 end, "the retries", 15_000)
      end)

    assert log =~ "mattermost:"
    refute log =~ "[REDACTED"
  end

  # This tree logs no SASL report: Elixir's primary `logger_translator` filter carries
  # `sasl: false` (`handle_sasl_reports` is unset), so a crash report from a process that is not a
  # GenServer reaches no handler at all, and a test reading the log would pass by reading nothing.
  # An operator can turn them on. So for this case they are on, in the filter's own place in the
  # primary list (the redaction filter stays after it, as it is in a running node).
  defp with_sasl_reports do
    %{filters: filters} = :logger.get_primary_config()

    on =
      Enum.map(filters, fn
        {:logger_translator, {fun, config}} -> {:logger_translator, {fun, %{config | sasl: true}}}
        other -> other
      end)

    :ok = :logger.update_primary_config(%{filters: on})
    on_exit(fn -> :logger.update_primary_config(%{filters: filters}) end)
  end

  test "AC6, error path: the socket crashes with the token in its connection" do
    with_sasl_reports()
    server = start_adapter!()
    old = Process.whereis(Socket)

    log =
      logged(fn ->
        # `use WebSockex`'s default `handle_cast/2` raises: a crash inside the process that holds
        # the connection struct, with its crash report written.
        WebSockex.cast(Socket, :no_such_cast)
        await(fn -> (pid = Process.whereis(Socket)) && pid != old end, "the socket to restart")
        await(fn -> length(FakeServer.connects(server)) >= 2 end, "the reconnect", 15_000)
        Process.sleep(100)
      end)

    # The crash report itself was read, not just the reconnect.
    assert log =~ "No handle_cast/2 clause"
    assert log =~ "Process Trinity.Gateways.Mattermost.Socket"
    assert log =~ "terminating"
    assert_clean(log, server.token)
  end

  test "AC6, error path: a dialog that will not open is logged without the request" do
    {command_env, _} = token!()
    server = start_adapter!(callback_url: "http://127.0.0.1:4072", command_token_env: command_env)
    previous = Application.get_env(:trinity, :gateways)
    Application.put_env(:trinity, :gateways, adapters: [Mattermost])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:trinity, :gateways, previous),
        else: Application.delete_env(:trinity, :gateways)
    end)

    token =
      Signing.button(
        [{"Approve once", "/approve 01a11aa0-0000-7000-8000-000000000000"}],
        "rebfe39yetygpyn11ma3gbairy",
        "Approval needed"
      )

    # The server will now refuse the adapter's token, so opening the dialog fails.
    System.put_env(server.token_env, FakeServer.random_id())

    log =
      logged(fn ->
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(
            "/gateways/callback/mattermost/action",
            Jason.encode!(%{
              "user_id" => tester_id(),
              "channel_id" => "rebfe39yetygpyn11ma3gbairy",
              "trigger_id" => "t",
              "context" => %{"token" => token}
            })
          )

        assert json_response(conn, 200)["ephemeral_text"] =~ "did not open"
      end)

    assert log =~ "the dialog did not open: HTTP 401"
    assert_clean(log, server.token)
  end

  test "the slash command's token and its response URL are filtered from the request log" do
    {command_env, command_token} = token!()
    response_hook = FakeServer.random_id()
    server = start_adapter!(command_token_env: command_env)
    start_supervised!(Router)
    previous = Application.get_env(:trinity, :gateways)
    Application.put_env(:trinity, :gateways, adapters: [Mattermost])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:trinity, :gateways, previous),
        else: Application.delete_env(:trinity, :gateways)
    end)

    log =
      logged(fn ->
        build_conn()
        |> post("/gateways/callback/mattermost/command", %{
          "token" => command_token,
          "user_id" => tester_id(),
          "channel_id" => "rebfe39yetygpyn11ma3gbairy",
          "text" => "help",
          "response_url" => "http://127.0.0.1:8065/hooks/commands/" <> response_hook
        })
      end)

    assert log =~ "GatewayCallbackController"
    assert log =~ "[FILTERED]"
    refute log =~ command_token
    refute log =~ response_hook
    refute log =~ server.token
  end
end
