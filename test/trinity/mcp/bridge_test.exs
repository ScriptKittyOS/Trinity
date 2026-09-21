# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.BridgeTest do
  @moduledoc """
  Slice 060 AC2 (an MCP tool call flows through the membrane's runner with `effect: :none`
  and yields a query receipt), AC3 (a row claiming `catalog` for a tool is refused at load
  with a receipt, and the changeset refuses it at write), and the result mapping (untrusted
  parts, a server error as `isError`).
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  import Trinity.MCP.ServersUnderTest

  alias Trinity.Effects
  alias Trinity.MCP.{Bridge, ServerConfig, Servers}
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools
  alias Trinity.Tools.Context

  setup do
    session = Trinity.Factory.session!()
    scope = Receipts.session_scope(session.id)
    ctx = %Context{session_id: session.id, caller: session.id, call_id: "c1"}
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, ctx: ctx, scope: scope}
  end

  defp allow!(tool) do
    {:ok, rule} = Permissions.put_rule(%{tool: tool, pattern: "*", decision: "allow"})
    on_exit(fn -> Permissions.revoke_rule(rule.id) end)
  end

  test "AC2: a call flows through Trinity.Effects.Runner with effect :none and yields a decision and a query receipt; the result is one untrusted part",
       %{ctx: ctx, scope: scope} do
    start!("b", :modern)
    await("b", :ready)
    allow!("mcp:b:add")

    assert {:ok, result, meta} =
             Effects.Runner.run(%{id: "c1", name: "mcp:b:add", args: %{"a" => 2, "b" => 3}}, ctx)

    assert result.content =~ ~s("sum": 5)

    assert [%{taint: :untrusted, origin: "tool:mcp:b:add", source_ref: "mcp://b/add"}] =
             result.parts

    assert result.meta["server"] == "b" and result.meta["is_error"] == false
    assert meta["tool"] == "mcp:b:add" and is_binary(meta["tool_definition_digest"])

    kinds = scope |> Receipts.list() |> Enum.map(&{&1.kind, &1.subject["tool"]})
    assert Enum.sort(kinds) == [{"decision", "mcp:b:add"}, {"query", "mcp:b:add"}]
  end

  test "a failing tool is a result the model reads as the server's error, not a crash", %{
    ctx: ctx
  } do
    start!("f", :modern)
    await("f", :ready)
    allow!("mcp:f:boom")

    assert {:ok, result, _} = Effects.Runner.run(%{id: "c1", name: "mcp:f:boom", args: %{}}, ctx)
    assert result.content =~ "[the server reported an error]" and result.content =~ "boom"
    assert result.meta["is_error"] == true
  end

  test "a tool with an artifact override crosses the membrane as an effect", %{
    ctx: ctx,
    scope: scope
  } do
    start!("a", :modern, %{tool_overrides: %{"echo" => %{"effect" => "artifact"}}})
    await("a", :ready)
    assert {:ok, %{effect: :artifact}} = Tools.lookup("mcp:a:echo")
    allow!("mcp:a:echo")

    assert {:ok, result, _} =
             Effects.Runner.run(%{id: "c1", name: "mcp:a:echo", args: %{"text" => "x"}}, ctx)

    assert result.content =~ ~s("echoed": "x")
    kinds = scope |> Receipts.list() |> Enum.map(&{&1.kind, &1.subject["phase"]})
    assert {"effect", "admit"} in kinds and {"effect", "done"} in kinds
  end

  test "AC3: a row claiming effect catalog for a tool is refused at load with a decision receipt on the server's scope, and the tool is not registered" do
    # The changeset refuses the claim at write.
    assert {:error, changeset} =
             Servers.create(
               attrs("c", :modern, %{tool_overrides: %{"echo" => %{"effect" => "catalog"}}})
             )

    assert %{tool_overrides: [msg]} = errors_on(changeset)
    assert msg =~ "catalog is compile time"

    # A row that carries the claim anyway (a struct built outside the changeset) is refused
    # at load: the registry's rule, receipted.
    config =
      struct(
        ServerConfig,
        attrs("c", :modern, %{tool_overrides: %{"echo" => %{"effect" => "catalog"}}})
      )

    {:ok, _pid} = Servers.start(config)
    on_exit(fn -> Trinity.MCP.Supervisor.stop_client("c") end)
    await("c", :ready)

    assert {:error, :unknown_tool} = Tools.lookup("mcp:c:echo")
    assert {:ok, _} = Tools.lookup("mcp:c:add")

    scope = Bridge.scope("c")
    on_exit(fn -> Receipts.stop_writer(scope) end)

    assert [receipt] = Receipts.list(scope)
    assert receipt.kind == "decision"
    assert receipt.subject == %{"server" => "c", "tool" => "mcp:c:echo", "phase" => "load"}
    payload = Jason.decode!(receipt.signed_payload)
    assert payload["decision"]["outcome"] == "deny"
    assert payload["decision"]["reason"] =~ "catalog_is_compile_time"
  end
end
