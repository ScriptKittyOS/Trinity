# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ServerMrtrTest do
  @moduledoc """
  Slice 061 AC7: an exchange begun against one instance of the server completes against another
  of the same release carrying only the `requestState`; a retry with the state altered, expired,
  replayed or bound to another call is refused; a retry with no state is a first call and is held
  on a new approval (a stateless server cannot tell the two apart, and the property that
  matters, no effect without a decided approval, holds). Two Plug instances with different
  server names, through the core's HTTP transport with `Plug.Test`, sharing the data directory
  (the envelope key) and the database (the approval); the replay table is reset between them
  where a second partition's fresh table is the point.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3]

  alias Trinity.MCP.Server.{Envelope, Exports, Replay}
  alias Trinity.Permissions
  alias Trinity.Receipts

  @token "mrtr-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}}
  }
  @args %{"action" => "add", "key" => "planet", "body" => "mars"}

  setup do
    System.put_env("TRINITY_MCP_SERVER_TOKEN", @token)
    Application.put_env(:trinity, :mcp_server, tools: Exports.defaults() ++ ["memory"])
    Replay.reset()
    :ok = Permissions.subscribe(:all)
    scope = Receipts.session_scope(Trinity.MCP.Server.Session.id())

    on_exit(fn ->
      System.delete_env("TRINITY_MCP_SERVER_TOKEN")
      Application.delete_env(:trinity, :mcp_server)
      Receipts.stop_writer(scope)
    end)

    a =
      Application.put_env(:trinity, :mcp_server,
        tools: Exports.defaults() ++ ["memory"],
        server_name: "instance-a"
      ) && Trinity.MCP.Server.Plug.init([])

    b =
      Application.put_env(:trinity, :mcp_server,
        tools: Exports.defaults() ++ ["memory"],
        server_name: "instance-b"
      ) && Trinity.MCP.Server.Plug.init([])

    {:ok, a: a, b: b, scope: scope}
  end

  defp call(instance, params, id \\ System.unique_integer([:positive])) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => Map.put(params, "_meta", @meta)
    }

    conn =
      :post
      |> conn("/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", params["name"])
      |> Trinity.MCP.Server.Plug.call(instance)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp memory(instance, extra \\ %{}),
    do: call(instance, Map.merge(%{"name" => "memory", "arguments" => @args}, extra))

  defp retry(instance, state),
    do: memory(instance, %{"requestState" => state, "inputResponses" => %{}})

  test "AC7: begun on instance A, decided by the owner, completed on instance B with the state alone; the effect ran once",
       %{a: a, b: b, scope: scope} do
    {200, %{"result" => %{"resultType" => "input_required", "requestState" => state} = held}} =
      memory(a)

    assert held["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "instance-a"
    assert_receive {:approval, :requested, %{id: aid}}, 2_000
    {:ok, _} = Permissions.decide_request(aid, :once, by: "test")

    # B is another partition: a fresh replay table, the same key and database.
    Replay.reset()

    {200, %{"result" => %{"resultType" => "complete", "isError" => false} = done}} =
      retry(b, state)

    assert done["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "instance-b"

    assert Enum.count(
             Receipts.list(scope),
             &(&1.kind == "effect" and &1.subject["phase"] == "done")
           ) == 1

    # The same state on A again (its table never saw the nonce: another partition, so the
    # table is reset once more) is the backstop's case: the once is consumed, so the gate asks
    # again and nothing runs twice.
    Replay.reset()
    {200, %{"result" => %{"resultType" => "input_required"}}} = retry(a, state)

    assert Enum.count(
             Receipts.list(scope),
             &(&1.kind == "effect" and &1.subject["phase"] == "done")
           ) == 1
  end

  test "a replay inside the partition, one tampered byte, an expired envelope and a state bound to other arguments are refused; a missing state is a first call",
       %{a: a, b: b, scope: scope} do
    {200, %{"result" => %{"resultType" => "input_required", "requestState" => state}}} = memory(a)
    assert_receive {:approval, :requested, %{id: aid}}, 2_000

    # Replay: the pending retry spends the nonce; the same state again is refused.
    {200, %{"result" => %{"resultType" => "input_required", "requestState" => fresh}}} =
      retry(a, state)

    {200, %{"error" => %{"code" => -32_602, "message" => "requestState already used"}}} =
      retry(a, state)

    # One byte altered: tampered, the plaintext never seen.
    {head, last} = String.split_at(fresh, -2)
    altered = head <> if(last == "AA", do: "AB", else: "AA")

    {200, %{"error" => %{"code" => -32_602, "message" => "requestState tampered"}}} =
      retry(a, altered)

    {200, %{"error" => %{"code" => -32_602, "message" => "requestState malformed"}}} =
      retry(a, "v9.nope")

    # Expired: sealed for zero seconds, opened a second later.
    # The formatter does not converge on `f(%{multi-line}, kw: v)`: the map is bound first.
    payload = %{
      approval_id: aid,
      session_id: Trinity.MCP.Server.Session.id(),
      call_id: Trinity.UUID.generate(),
      tool: "memory",
      args_digest: Envelope.args_digest(@args)
    }

    expired = Envelope.seal(payload, ttl_s: 0)

    Process.sleep(1_100)

    {200, %{"error" => %{"code" => -32_602, "message" => "requestState expired"}}} =
      retry(b, expired)

    # Bound to other arguments: refused as not this call's.
    {200,
     %{"error" => %{"code" => -32_602, "message" => "requestState does not belong to this call"}}} =
      call(b, %{
        "name" => "memory",
        "arguments" => Map.put(@args, "body", "venus"),
        "requestState" => fresh,
        "inputResponses" => %{}
      })

    # Missing: a first call, held on a new approval; nothing ran.
    {200, %{"result" => %{"resultType" => "input_required"}}} = memory(b)
    assert_receive {:approval, :requested, %{id: other}}, 2_000
    assert other != aid
    assert Enum.count(Receipts.list(scope), &(&1.kind == "effect")) == 0
  end
end
