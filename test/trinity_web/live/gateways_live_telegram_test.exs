# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.GatewaysLiveTelegramTest do
  @moduledoc """
  Slice 071, "UI status": `/gateways` shows what the Telegram adapter is doing beside whether it
  runs: which bot it polls as, idle because there is no token, or the last error.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.FakeTelegram.BotApi
  alias Trinity.Gateways.{Router, Telegram}
  alias Trinity.Gateways.Telegram.Outbox

  setup do
    Application.put_env(:trinity, :gateways, adapters: [Telegram])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)
    :ok
  end

  defp await(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never became true")
      true -> Process.sleep(25) && await(fun, tries - 1)
    end
  end

  test "the page says which bot the adapter polls as", %{conn: conn} do
    _fake = BotApi.start!()
    start_supervised!(Router)
    start_supervised!(Telegram)
    await(fn -> Outbox.status().state == :running end)

    {:ok, _view, html} = live(conn, ~p"/gateways")
    assert html =~ "telegram"
    assert html =~ "running"
    assert html =~ "polling as @trinity_test_bot"
    assert html =~ "4096"
  end

  test "without a token the adapter is idle and the page says why", %{conn: conn} do
    _fake = BotApi.start!(token: false)
    previous = System.get_env("TELEGRAM_BOT_TOKEN")
    System.delete_env("TELEGRAM_BOT_TOKEN")
    on_exit(fn -> if previous, do: System.put_env("TELEGRAM_BOT_TOKEN", previous) end)

    start_supervised!(Router)
    start_supervised!(Telegram)

    # The poller declined to start; the outbox runs and reports why.
    assert Process.whereis(Trinity.Gateways.Telegram.Poller) == nil

    {:ok, _view, html} = live(conn, ~p"/gateways")
    assert html =~ "idle: TELEGRAM_BOT_TOKEN is not set"
  end
end
