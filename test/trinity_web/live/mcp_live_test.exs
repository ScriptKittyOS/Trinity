# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.MCPLiveTest do
  @moduledoc """
  Slice 060, the pages: `/mcp` lists a server with its health and tools, adds one from the
  form, disables, enables and removes it; the permissions page renders a server's input
  request as a form whose answer decides the approval (the multi-round-trip card).
  """
  use TrinityWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Trinity.MCP.ServersUnderTest

  alias Trinity.MCP.Servers
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval

  test "the page lists a server with its status, revision and tools; disable, enable and remove act on the row and the client",
       %{conn: conn} do
    start!("page", :modern)
    await("page", :ready)

    {:ok, view, html} = live(conn, ~p"/mcp")
    assert html =~ "page" and html =~ "2026-07-28" and html =~ "3 tools"
    assert has_element?(view, "#server-page", "ready")

    view |> element("#server-page button", "page") |> render_click()
    assert has_element?(view, "#server-page td", "mcp:page:echo")
    assert has_element?(view, "#server-page td", "Echoes the text")

    [%{config: config}] = Servers.status()
    view |> element("#server-page button", "disable") |> render_click()
    assert has_element?(view, "#server-page", "disabled")
    assert Trinity.MCP.Client.whereis("page") == nil
    assert %{enabled: false} = Servers.get(config.id)

    view |> element("#server-page button", "enable") |> render_click()
    await("page", :ready)
    assert is_pid(Trinity.MCP.Client.whereis("page"))

    view |> element("#server-page button", "remove") |> render_click()
    refute has_element?(view, "#server-page")
    assert Servers.list() == []
  end

  test "the form adds an http server, which connects; a bad row shows its errors", %{conn: conn} do
    url = http_server!()
    {:ok, view, _} = live(conn, ~p"/mcp")
    on_exit(fn -> Trinity.MCP.Supervisor.stop_client("added") end)

    # Choosing the transport shows its fields.
    view |> form("#server-form", %{"server" => %{"transport" => "http"}}) |> render_change()
    assert has_element?(view, "#server-form input[name='server[url]']")

    view
    |> form("#server-form", %{
      "server" => %{"name" => "Bad Name", "transport" => "http", "url" => ""}
    })
    |> render_submit()

    assert has_element?(view, "#server-form p", "name:")
    assert has_element?(view, "#server-form p", "url:")

    view
    |> form("#server-form", %{
      "server" => %{"name" => "added", "transport" => "http", "url" => url}
    })
    |> render_submit()

    assert has_element?(view, "#server-added")
    await("added", :ready)
    assert render(view) =~ "added"
    assert [%{config: %{name: "added", transport: "http"}}] = Servers.status()
  end

  test "an approval carrying a server's input request renders as a form; answering decides once with the typed answer",
       %{conn: conn} do
    request = %{
      "kind" => "mcp_input",
      "server" => "q",
      "inputRequests" => %{
        "who" => %{
          "method" => "elicitation/create",
          "params" => %{
            "mode" => "form",
            "message" => "What is your name, and how many?",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string", "title" => "Name"},
                "count" => %{"type" => "integer"},
                "sure" => %{"type" => "boolean"},
                "colour" => %{"type" => "string", "enum" => ["red", "blue"]}
              },
              "required" => ["name"]
            }
          }
        }
      }
    }

    {:ok, %Approval{id: aid}} =
      Permissions.request_approval(nil, "mcp:q:ask_name", %{"greeting" => "Hi"},
        risk: :ask,
        request: request
      )

    {:ok, view, html} = live(conn, ~p"/permissions")
    assert html =~ "The MCP server q asks" and html =~ "What is your name, and how many?"
    assert has_element?(view, "#answer-#{aid} input[name='answer[who][name]'][required]")
    assert has_element?(view, "#answer-#{aid} input[name='answer[who][count]'][type=number]")

    assert has_element?(
             view,
             "#answer-#{aid} select[name='answer[who][colour]'] option[value=blue]"
           )

    refute html =~ "requestState"

    view
    |> form("#answer-#{aid}", %{
      "answer" => %{
        "who" => %{"name" => "Ayla", "count" => "3", "sure" => "true", "colour" => "blue"}
      }
    })
    |> render_submit()

    assert %Approval{status: "allowed", decision: "once", answer: answer} =
             Permissions.get_approval(aid)

    assert answer == %{
             "who" => %{
               "action" => "accept",
               "content" => %{"name" => "Ayla", "count" => 3, "sure" => true, "colour" => "blue"}
             }
           }

    refute has_element?(view, "#answer-#{aid}")
  end

  # Slice 062: the client role's one piece of page: the challenge and "authorize".
  test "a server that answered 401 with resource metadata shows the challenge; authorize sends the owner to the AS",
       %{conn: conn} do
    as = Trinity.MCP.FakeAS.start!()
    {:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
    resource = "http://127.0.0.1:#{port}/mcp"
    store = Path.join(System.tmp_dir!(), "oauth-store-#{System.unique_integer([:positive])}")

    Application.put_env(:trinity, :mcp_auth,
      profile: :production,
      issuer: as.issuer,
      resource: resource,
      client_id: "trinity-page",
      store_dir: store
    )

    Trinity.MCP.AuthHost.reload()

    on_exit(fn ->
      Application.delete_env(:trinity, :mcp_auth)
      Trinity.MCP.AuthHost.reload()
      Trinity.MCP.Auth.JWKS.forget(as.issuer)
      File.rm_rf(store)
    end)

    start!("prot", {:http, resource})
    await("prot", :down)

    {:ok, view, _} = live(conn, ~p"/mcp")
    assert has_element?(view, "#server-prot", "Needs authorization")
    assert has_element?(view, "#server-prot", "/.well-known/oauth-protected-resource/mcp")

    assert {:error, {:redirect, %{to: url}}} =
             view |> element("#server-prot button", "authorize") |> render_click()

    assert String.starts_with?(url, as.issuer <> "/authorize?")
    query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query["client_id"] == "trinity-page" and query["resource"] == resource
    assert query["redirect_uri"] == TrinityWeb.Endpoint.url() <> "/oauth/callback"
    assert query["code_challenge_method"] == "S256"
  end

  test "declining a server's request denies the approval", %{conn: conn} do
    request = %{
      "kind" => "mcp_input",
      "server" => "q",
      "inputRequests" => %{
        "who" => %{"method" => "elicitation/create", "params" => %{"message" => "?"}}
      }
    }

    {:ok, %Approval{id: aid}} =
      Permissions.request_approval(nil, "mcp:q:t", %{}, risk: :ask, request: request)

    {:ok, view, _} = live(conn, ~p"/permissions")
    view |> element("#approval-#{aid} button", "Decline") |> render_click()
    assert %Approval{status: "denied"} = Permissions.get_approval(aid)
  end
end
