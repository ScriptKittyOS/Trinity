# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.GatewaysLiveTest do
  @moduledoc """
  Slice 070, AC9's automatic half: `/gateways` lists the configured channels with the tier each
  may approve, shows a waiting identity's pairing code, and allows or revokes one. The code is
  shown on this page and nowhere else, which is what makes reading it the proof of pairing.
  """
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Gateways.{Console, Identities}

  setup do
    start_supervised!(Console)
    Application.put_env(:trinity, :gateways, adapters: [Console])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)
    :ok
  end

  test "the page lists the channel, whether it runs, and the tier it may approve", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/gateways")
    assert html =~ "console"
    assert html =~ "running"
    assert html =~ "approves up to"
    assert html =~ "write"
    assert html =~ "permissions page"
  end

  test "a waiting identity's code is shown here, and allow pairs it without a code", %{conn: conn} do
    {:ok, identity, :pending} = Identities.admit("console", "u-1", display_name: "Someone")

    {:ok, view, html} = live(conn, ~p"/gateways")
    assert html =~ identity.code
    assert html =~ "console:u-1"
    assert html =~ "Someone"

    view |> element("#identity-#{identity.id} button", "allow") |> render_click()
    assert Identities.get("console", "u-1").state == "paired"
    refute render(view) =~ identity.code
  end

  test "revoking keeps the row and shows it as revoked", %{conn: conn} do
    {:ok, identity, :pending} = Identities.admit("console", "u-2")

    {:ok, view, _html} = live(conn, ~p"/gateways")
    view |> element("#identity-#{identity.id} button", "revoke") |> render_click()

    assert Identities.get("console", "u-2").state == "revoked"
    html = render(view)
    assert html =~ "u-2"
    assert html =~ "revoked"
  end

  test "with no identity and no adapter configured the page says so", %{conn: conn} do
    Application.put_env(:trinity, :gateways, adapters: [])
    {:ok, _view, html} = live(conn, ~p"/gateways")
    assert html =~ "No gateway is configured"
    assert html =~ "Nobody is waiting"
    assert html =~ "No identity has written yet"
  end
end
