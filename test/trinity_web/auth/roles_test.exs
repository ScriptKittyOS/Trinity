# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.RolesTest do
  @moduledoc """
  Slice 136 AC8: what each role may do, through the whole endpoint and the LiveView hooks.

  Without `administer`: `403` on `/oban`, `/dev/dashboard` and the export with and without
  `keys=1`; the `/mcp` "create" event and the `/gateways` "allow" event are halted before their
  handlers run (nothing is created, nobody is paired). `approve` without `administer` cannot
  export. `administer` without `approve` cannot decide an approval (separation of duties). And the
  positive halves, so a role check that refuses everyone fails here too.

  An event refused by the hook is told apart from one its handler refused by the flash: the hook
  says "Not permitted", a handler that ran and failed says something else.
  """
  use TrinityWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import TrinityWeb.WebAuthHelpers

  alias Trinity.Gateways.Identities
  alias Trinity.MCP.Servers

  setup do
    web_auth!(:oidc)
    :ok
  end

  defp as(roles), do: build_conn() |> log_in_web(roles) |> elem(0)

  defp status(conn, path), do: conn |> get(path) |> Map.fetch!(:status)

  describe "privileged routes" do
    test "view and approve get 403 on the export, keys or not, /oban and /dev/dashboard" do
      for roles <- [[:view], [:approve], [:view, :approve]] do
        conn = as(roles)

        for path <- [
              "/settings/export.tar.gz",
              "/settings/export.tar.gz?keys=1",
              "/oban",
              "/dev/dashboard"
            ] do
          assert status(conn, path) == 403, "#{inspect(roles)} reached #{path}"
        end
      end
    end

    # `/oban`'s page cannot mount in the suite (Oban.Met is not running; see tasks_live_test), so
    # the administer half reads its asset route, which runs the same two pipelines.
    test "administer reaches the dashboards and the export" do
      conn = as([:administer])
      assert status(conn, "/dev/dashboard/home") == 200
      assert status(conn, "/oban/css-0") == 200
      assert status(as([:view]), "/oban/css-0") == 403

      conn = get(conn, "/settings/export.tar.gz")
      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "trinity-"
    end

    test "every role reaches the ordinary pages" do
      for roles <- [[:view], [:approve], [:administer]] do
        assert status(as(roles), "/mcp") == 200
        assert status(as(roles), "/gateways") == 200
      end
    end
  end

  describe "privileged events" do
    test "view cannot add an MCP server; administer can" do
      {:ok, view, _} = live(as([:view]), "/mcp")
      view |> form("#server-form", %{"server" => %{"transport" => "http"}}) |> render_change()

      html =
        view
        |> form("#server-form", %{
          "server" => %{
            "name" => "viewer",
            "transport" => "http",
            "url" => "http://127.0.0.1:1/mcp"
          }
        })
        |> render_submit()

      assert html =~ "Not permitted"
      assert Servers.list() == []

      on_exit(fn -> Trinity.MCP.Supervisor.stop_client("admin") end)
      {:ok, view, _} = live(as([:administer]), "/mcp")
      view |> form("#server-form", %{"server" => %{"transport" => "http"}}) |> render_change()

      view
      |> form("#server-form", %{
        "server" => %{"name" => "admin", "transport" => "http", "url" => "http://127.0.0.1:1/mcp"}
      })
      |> render_submit()

      assert [%{name: "admin"}] = Servers.list()
    end

    test "view and approve cannot pair a gateway identity; administer can" do
      {:ok, identity, :pending} = Identities.admit("console", "u-role")

      for roles <- [[:view], [:approve]] do
        {:ok, view, _} = live(as(roles), "/gateways")
        html = view |> element("#identity-#{identity.id} button", "allow") |> render_click()
        assert html =~ "Not permitted"
        assert Identities.get("console", "u-role").state == "pending"
      end

      {:ok, view, _} = live(as([:administer]), "/gateways")
      view |> element("#identity-#{identity.id} button", "allow") |> render_click()
      assert Identities.get("console", "u-role").state == "paired"
    end

    test "deciding an approval needs approve: administer alone is refused, approve reaches the handler" do
      args = %{"id" => "no-such-approval", "decision" => "once"}

      {:ok, view, _} = live(as([:administer]), "/permissions")
      assert render_hook(view, "approval_decide", args) =~ "Not permitted"

      {:ok, view, _} = live(as([:view]), "/permissions")
      assert render_hook(view, "approval_decide", args) =~ "Not permitted"

      # The handler ran and answered for itself: the request does not exist.
      {:ok, view, _} = live(as([:approve]), "/permissions")
      html = render_hook(view, "approval_decide", args)
      refute html =~ "Not permitted"
      assert html =~ "Not decided"
    end
  end
end
