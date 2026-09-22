# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ServerTest do
  @moduledoc """
  Slice 061 AC1 (our 060 client connects to our own `/mcp` at 2026-07-28 and lists the exported
  tools; a 2025-11-25 wire against the wrapper connects with `initialize` and calls a tool), AC2
  (`tools/list` deterministic with `ttlMs` and `cacheScope`), AC3 (`recall` over MCP yields a
  query receipt with `origin: "mcp"`), AC4 (an `:artifact` tool: `input_required`, the approval
  on the permissions page, the retry succeeds; a denial is an error and a receipt), AC5 (a
  `:catalog` tool is not exportable), and the bearer.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  import Trinity.MCP.ServersUnderTest, only: [start!: 3, await: 2]

  alias Trinity.MCP.Client
  alias Trinity.MCP.Server
  alias Trinity.MCP.Server.{Catalog, Exports, Replay}
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools

  @token "test-bearer-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}}
  }

  setup do
    System.put_env("TRINITY_MCP_SERVER_TOKEN", @token)
    System.put_env("TRINITY_MCP_SELF_TOKEN", @token)
    Application.put_env(:trinity, :mcp_server, tools: Exports.defaults() ++ ["memory"])
    Replay.reset()
    scope = Receipts.session_scope(Trinity.MCP.Server.Session.id())

    on_exit(fn ->
      System.delete_env("TRINITY_MCP_SERVER_TOKEN")
      System.delete_env("TRINITY_MCP_SELF_TOKEN")
      Application.delete_env(:trinity, :mcp_server)
      Receipts.stop_writer(scope)
    end)

    {:ok, url: url(), scope: scope}
  end

  defp url do
    {:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp connect!(url) do
    start!("self", {:http, url}, %{})
    await("self", :ready)
  end

  defp wrapper, do: Server.new(catalog: Catalog, server_name: "trinity-test")

  defp request(id, method, params, meta \\ @meta),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }

  test "AC1: our client connects at 2026-07-28 over /mcp and lists the exported tools under mcp:self:*",
       %{url: url} do
    assert %{revision: "2026-07-28", registered: registered} = connect!(url)

    assert Enum.sort(registered) ==
             Enum.sort(for t <- Exports.defaults() ++ ["memory"], do: "mcp:self:" <> t)

    assert {:ok, %{spec: %{schema: %{"properties" => %{"query" => _}}}}} =
             Tools.lookup("mcp:self:recall")
  end

  test "AC1: a 2025-11-25 client connects to the wrapper with initialize and calls a tool; the answers carry no resultType" do
    state = wrapper()

    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "old", "version" => "1"}
      }
    }

    {state, %{"result" => %{"protocolVersion" => "2025-11-25"}}} =
      Server.handle_message(state, init)

    {state, nil} =
      Server.handle_message(state, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    {state, %{"result" => %{"tools" => tools} = list}} =
      Server.handle_message(state, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      })

    assert Enum.map(tools, & &1["name"]) == Enum.sort(Exports.defaults() ++ ["memory"])
    refute Map.has_key?(list, "resultType")

    {_state, %{"result" => result}} =
      Server.handle_message(state, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "skills_list", "arguments" => %{}}
      })

    assert [%{"type" => "text"}] = result["content"]
    assert result["isError"] == false
    refute Map.has_key?(result, "resultType")
  end

  test "AC2: tools/list is sorted, identical across two calls, and carries ttlMs and cacheScope" do
    state = wrapper()
    {state, %{"result" => a}} = Server.handle_message(state, request(1, "tools/list", %{}))
    {_state, %{"result" => b}} = Server.handle_message(state, request(2, "tools/list", %{}))
    names = Enum.map(a["tools"], & &1["name"])
    assert names == Enum.sort(names) and names == Enum.sort(Exports.defaults() ++ ["memory"])
    assert a["tools"] == b["tools"]
    assert a["ttlMs"] == 0 and a["cacheScope"] == "private"
    assert a["resultType"] == "complete"

    assert %{"readOnlyHint" => true} =
             Enum.find(a["tools"], &(&1["name"] == "recall"))["annotations"]

    assert %{"readOnlyHint" => false, "destructiveHint" => true} =
             Enum.find(a["tools"], &(&1["name"] == "memory"))["annotations"]
  end

  test "AC3: recall over /mcp yields a decision and a query receipt whose subject carries origin mcp",
       %{url: url, scope: scope} do
    connect!(url)
    {:ok, rule} = Permissions.put_rule(%{tool: "recall", pattern: "*", decision: "allow"})
    on_exit(fn -> Permissions.revoke_rule(rule.id) end)

    assert {:ok,
            %{
              "result" => %{
                "resultType" => "complete",
                "isError" => false,
                "content" => [%{"type" => "text"}]
              }
            }} =
             Client.call("self", "recall", %{"query" => "anything at all"})

    kinds =
      scope |> Receipts.list() |> Enum.map(&{&1.kind, &1.subject["tool"], &1.subject["origin"]})

    assert {"decision", "recall", "mcp"} in kinds and {"query", "recall", "mcp"} in kinds
  end

  test "the trace context in _meta rides into the receipts' meta", %{scope: scope} do
    {:ok, rule} = Permissions.put_rule(%{tool: "skills_list", pattern: "*", decision: "allow"})
    on_exit(fn -> Permissions.revoke_rule(rule.id) end)

    meta =
      Map.put(@meta, "traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")

    {_state, %{"result" => %{"resultType" => "complete"}}} =
      Server.handle_message(
        wrapper(),
        request(1, "tools/call", %{"name" => "skills_list", "arguments" => %{}}, meta)
      )

    assert Enum.any?(
             Receipts.list(scope),
             &(&1.meta["trace"]["traceparent"] ==
                 "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
           )
  end

  test "AC4: an artifact tool is held as input_required with a sealed state; approving on the permissions page lets the retry complete; denying makes the retry an error with its receipt",
       %{url: url, scope: scope} do
    connect!(url)
    :ok = Permissions.subscribe(:all)
    args = %{"action" => "add", "key" => "colour", "body" => "blue"}

    assert {:ok,
            %{
              "result" => %{
                "resultType" => "input_required",
                "requestState" => state,
                "inputRequests" => reqs
              }
            }} =
             Client.call("self", "memory", args)

    assert %{
             "approval" => %{
               "method" => "elicitation/create",
               "params" => %{"message" => message}
             }
           } = reqs

    assert message =~ "approval" and message =~ "permissions page"
    assert String.starts_with?(state, "v1.")
    assert_receive {:approval, :requested, %{id: aid, tool: "memory", session_id: sid}}, 2_000
    assert sid == Trinity.MCP.Server.Session.id()

    # Retried before the decision: held again, under a fresh state; the old nonce is spent.
    assert {:ok, %{"result" => %{"resultType" => "input_required", "requestState" => state2}}} =
             Client.call("self", "memory", args,
               continuation: %{
                 responses: %{
                   "approval" => %{"action" => "accept", "content" => %{"retry" => true}}
                 },
                 state: state
               }
             )

    assert state2 != state

    # The owner decides on the page; the retry with the current state completes the call.
    {:ok, _} = Permissions.decide_request(aid, :once, by: "test")

    assert {:ok,
            %{
              "result" => %{
                "resultType" => "complete",
                "isError" => false,
                "content" => [%{"text" => text}]
              }
            }} =
             Client.call("self", "memory", args,
               continuation: %{
                 responses: %{
                   "approval" => %{"action" => "accept", "content" => %{"retry" => true}}
                 },
                 state: state2
               }
             )

    assert text =~ "colour"
    kinds = scope |> Receipts.list() |> Enum.map(&{&1.kind, &1.subject["phase"]})
    assert {"effect", "admit"} in kinds and {"effect", "done"} in kinds

    # Denied: the retry is a tool error, and the decision receipt says deny.
    args2 = %{"action" => "add", "key" => "shape", "body" => "round"}

    assert {:ok, %{"result" => %{"resultType" => "input_required", "requestState" => s3}}} =
             Client.call("self", "memory", args2)

    assert_receive {:approval, :requested, %{id: aid2}}, 2_000
    {:ok, _} = Permissions.decide_request(aid2, :deny, by: "test")

    assert {:ok,
            %{
              "result" => %{
                "resultType" => "complete",
                "isError" => true,
                "content" => [%{"text" => "denied" <> _}]
              }
            }} =
             Client.call("self", "memory", args2, continuation: %{responses: %{}, state: s3})

    denied =
      scope
      |> Receipts.list()
      |> Enum.filter(&(&1.kind == "decision"))
      |> Enum.map(&Jason.decode!(&1.signed_payload)["decision"]["outcome"])

    assert "deny" in denied
  end

  test "AC5: a catalog tool is not exportable; an unknown name and a dynamic name are refused too" do
    assert {[], [{"shell", :catalog_is_not_exportable}]} = Exports.resolve(["shell"])
    assert {[], [{"nope", :unknown_tool}]} = Exports.resolve(["nope"])
    Application.put_env(:trinity, :mcp_server, tools: ["shell", "recall"])
    assert %{tools: [%{name: :recall}]} = Catalog.capabilities()
  end

  test "the bearer: a wrong or absent one is refused before anything is decoded; the right one reaches discover",
       %{url: url} do
    body = Jason.encode!(request(1, "server/discover", %{}))

    headers = [
      {"content-type", "application/json"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "server/discover"}
    ]

    # Slice 062: a refusal is 401 with a WWW-Authenticate challenge (RFC 6750), decided by the
    # profile before the transport; 061's transport-side refusal answered 403.
    assert {:ok, %Req.Response{status: 401} = r} =
             Req.post(url, headers: headers, body: body, retry: false)

    assert ["Bearer" <> _] = Req.Response.get_header(r, "www-authenticate")

    assert {:ok, %Req.Response{status: 401}} =
             Req.post(url,
               headers: [{"authorization", "Bearer nope"} | headers],
               body: body,
               retry: false
             )

    assert {:ok, %Req.Response{status: 200, body: answer}} =
             Req.post(url,
               headers: [{"authorization", "Bearer " <> @token} | headers],
               body: body,
               retry: false,
               decode_body: false
             )

    assert %{"result" => %{"supportedVersions" => ["2026-07-28"], "resultType" => "complete"}} =
             Jason.decode!(answer)
  end

  # fix(s062). `Plug.Builder` calls a plug's `init/1` at compile time in `:prod` and escapes what
  # it returns into the compiled endpoint, so an option that cannot be escaped breaks the release
  # build and nothing else: the gate runs in `:test`, where `init/1` is called per request, and
  # was green over it for the whole of slice 062. This is that compile-time step, in a test.
  test "every option the plug's init returns can be escaped, as a compile-time init must be" do
    opts = Trinity.MCP.Server.Plug.init([])
    assert is_list(opts) or is_map(opts)
    assert Macro.escape(opts)

    # The authorize hook is the option that broke it: a remote capture escapes, a closure does not.
    assert_raise ArgumentError, ~r/cannot escape/, fn ->
      Macro.escape(authorize: fn _conn -> :ok end)
    end
  end
end
