# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.ResourceServerTest do
  @moduledoc """
  Slice 062 through the endpoint, in the production profile against the fake enterprise AS:
  AC1 (unauthenticated is 401 with `resource_metadata`; the PRM names the AS; wrong audience and
  expired are 401; each refusal receipted with what could be read), AC4 (a read scope cannot
  call an artifact tool; the artifact scope can, subject to the gate), and the owner's three
  constraints: no dispatch without an audience-bound token (the local profile's bearer means
  nothing here), the receipts of a call name issuer, subject and scope, and no token material
  reaches the context or the rows.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  alias Trinity.MCP.AuthHost
  alias Trinity.MCP.Auth.JWKS
  alias Trinity.MCP.FakeAS
  alias Trinity.MCP.Server.{Exports, Replay}
  alias Trinity.Permissions
  alias Trinity.Receipts

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}}
  }

  setup do
    as = FakeAS.start!()
    {:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
    resource = "http://127.0.0.1:#{port}/mcp"

    Application.put_env(:trinity, :mcp_auth,
      profile: :production,
      issuer: as.issuer,
      resource: resource
    )

    Application.put_env(:trinity, :mcp_server, tools: Exports.defaults() ++ ["memory"])
    AuthHost.reload()
    Replay.reset()
    scope = Receipts.session_scope(Trinity.MCP.Server.Session.id())

    on_exit(fn ->
      Application.delete_env(:trinity, :mcp_auth)
      Application.delete_env(:trinity, :mcp_server)
      AuthHost.reload()
      JWKS.forget(as.issuer)
      Receipts.stop_writer(scope)
    end)

    {:ok, as: as, resource: resource, scope: scope, port: port}
  end

  defp post(resource, token, method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", @meta)
    }

    headers =
      [
        {"content-type", "application/json"},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", method}
      ] ++
        if(params["name"], do: [{"mcp-name", params["name"]}], else: []) ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    {:ok, r} =
      Req.post(resource,
        headers: headers,
        body: Jason.encode!(body),
        retry: false,
        decode_body: false
      )

    {r.status, Req.Response.get_header(r, "www-authenticate"), Jason.decode!(r.body)}
  end

  defp decisions(scope), do: scope |> Receipts.list() |> Enum.filter(&(&1.kind == "decision"))

  test "AC1: 401 with resource_metadata; the PRM names the AS; wrong audience, expired and the static bearer are 401; each refusal receipted",
       %{as: as, resource: resource, scope: scope, port: port} do
    assert {401, ["Bearer resource_metadata=\"" <> rest], %{"error" => %{"code" => -32001}}} =
             post(resource, nil, "server/discover", %{})

    prm_url = String.trim_trailing(rest, "\"")
    assert prm_url == "http://127.0.0.1:#{port}/.well-known/oauth-protected-resource/mcp"

    {:ok, %Req.Response{status: 200, body: prm}} = Req.get(prm_url, retry: false)
    assert %{"resource" => ^resource, "authorization_servers" => [issuer]} = prm
    assert issuer == as.issuer

    assert {401, _, _} =
             post(
               resource,
               FakeAS.mint(as, %{"aud" => "http://other/mcp"}),
               "server/discover",
               %{}
             )

    assert {401, _, _} =
             post(
               resource,
               FakeAS.mint(as, %{"aud" => resource, "exp" => System.os_time(:second) - 300}),
               "server/discover",
               %{}
             )

    # 061's static bearer is not a token in this profile.
    System.put_env("TRINITY_MCP_SERVER_TOKEN", "static-bearer")
    on_exit(fn -> System.delete_env("TRINITY_MCP_SERVER_TOKEN") end)
    assert {401, _, _} = post(resource, "static-bearer", "server/discover", %{})

    # The right token reaches the core.
    assert {200, [], %{"result" => %{"supportedVersions" => ["2026-07-28"]}}} =
             post(resource, FakeAS.mint(as, %{"aud" => resource}), "server/discover", %{})

    reasons =
      for r <- decisions(scope),
          r.subject["phase"] == "auth",
          do: Jason.decode!(r.signed_payload)["decision"]["reason"]

    assert "no_bearer" in reasons
    assert Enum.any?(reasons, &String.starts_with?(&1, "wrong_audience"))
    assert "expired" in reasons
    assert "malformed" in reasons

    claimed =
      for r <- decisions(scope),
          r.subject["phase"] == "auth",
          r.subject["claimed_sub"],
          do: {r.subject["claimed_sub"], r.subject["unverified"]}

    assert {"u@example.com", true} in claimed
    refute Enum.any?(Receipts.list(scope), &(inspect(&1) =~ "eyJ"))
  end

  test "AC4 and the receipts: read scope refused on an artifact tool, artifact scope reaches the gate, receipts name the principal, no token material",
       %{as: as, resource: resource, scope: scope} do
    {:ok, rule} = Permissions.put_rule(%{tool: "skills_list", pattern: "*", decision: "allow"})
    on_exit(fn -> Permissions.revoke_rule(rule.id) end)

    read_only =
      FakeAS.mint(as, %{
        "aud" => resource,
        "scope" => "trinity:tools:read",
        "sub" => "reader@example.com"
      })

    assert {200, _,
            %{
              "error" => %{
                "code" => -32001,
                "message" => "insufficient scope: this tool needs trinity:tools:artifact"
              }
            }} =
             post(resource, read_only, "tools/call", %{
               "name" => "memory",
               "arguments" => %{"action" => "add", "key" => "k", "body" => "b"}
             })

    [deny] = for r <- decisions(scope), r.subject["tool"] == "memory", do: r

    assert %{
             "principal" => %{
               "iss" => iss,
               "sub" => "reader@example.com",
               "scope" => "trinity:tools:read"
             }
           } = deny.subject

    assert iss == as.issuer

    assert Jason.decode!(deny.signed_payload)["decision"] == %{
             "outcome" => "deny",
             "basis" => "scope",
             "reason" => "needs trinity:tools:artifact"
           }

    # The artifact scope reaches the gate, which holds the call for the owner (061's loop).
    writer =
      FakeAS.mint(as, %{
        "aud" => resource,
        "scope" => "trinity:tools:artifact",
        "sub" => "writer@example.com"
      })

    assert {200, _, %{"result" => %{"resultType" => "input_required"}}} =
             post(resource, writer, "tools/call", %{
               "name" => "memory",
               "arguments" => %{"action" => "add", "key" => "k", "body" => "b"}
             })

    # A read under an allow rule runs, and its decision and query receipts name the principal.
    assert {200, _, %{"result" => %{"resultType" => "complete", "isError" => false}}} =
             post(resource, read_only, "tools/call", %{
               "name" => "skills_list",
               "arguments" => %{}
             })

    named =
      for r <- Receipts.list(scope),
          r.subject["tool"] == "skills_list",
          do: {r.kind, r.subject["principal"]}

    assert {"decision",
            %{
              "iss" => as.issuer,
              "sub" => "reader@example.com",
              "scope" => "trinity:tools:read",
              "client_id" => "test-client",
              "profile" => "production"
            }} in named

    assert {"query",
            %{
              "iss" => as.issuer,
              "sub" => "reader@example.com",
              "scope" => "trinity:tools:read",
              "client_id" => "test-client",
              "profile" => "production"
            }} in named

    # No token material: not in any receipt, not in any message of the MCP session.
    refute Enum.any?(Receipts.list(scope), &(inspect(&1) =~ "eyJ"))

    refute Enum.any?(
             Trinity.Sessions.history(Trinity.MCP.Server.Session.id()),
             &(inspect(&1) =~ "eyJ")
           )
  end
end
