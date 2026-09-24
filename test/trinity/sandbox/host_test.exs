# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.HostTest do
  @moduledoc """
  Slice 110 AC4: a tool call made from Lua is decided by the same gate as any other.

  The claim worth testing is not that `trinity.tool` works. It is that it is **not a second door**:
  it goes through `Trinity.Effects.Runner.execute/3`, the executor a model's own tool call uses, so
  a denial denies it and an approval requirement stops it.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  alias Trinity.Permissions
  alias Trinity.Sandbox
  alias Trinity.Tools.Context

  setup do
    session = Trinity.Factory.session!()
    scope = Trinity.Receipts.session_scope(session.id)
    on_exit(fn -> Trinity.Receipts.stop_writer(scope) end)
    {:ok, ctx: %Context{session_id: session.id, caller: session.id, call_id: "lua"}}
  end

  defp rule!(tool, decision) do
    {:ok, rule} = Permissions.put_rule(%{tool: tool, pattern: "*", decision: decision})
    on_exit(fn -> Permissions.revoke_rule(rule.id) end)
  end

  test "with no context a script gets the interpreter and no host surface", %{ctx: _} do
    # The default is the safe one: a caller has to say whose authority a script runs under before
    # it can reach a tool at all.
    assert {:ok, [nil], _} = Sandbox.run("return trinity")
  end

  test "an allowed tool call runs and its content comes back to Lua", %{ctx: ctx} do
    rule!("echo", "allow")

    assert {:ok, ["hi"], _stats} =
             Sandbox.run(~s|return trinity.tool("echo", {text = "hi"})|, context: ctx)
  end

  test "a denied tool call returns nil and a message, and does not abort the script", %{ctx: ctx} do
    rule!("echo", "deny")

    code = """
    local v, err = trinity.tool("echo", {text = "hi"})
    if v == nil then return "refused: " .. tostring(err) end
    return "ran"
    """

    assert {:ok, [answer], _} = Sandbox.run(code, context: ctx)
    assert answer =~ "refused:"

    refute answer == "ran",
           "the gate said deny and the script still got a value, so Lua is a second door"
  end

  test "a call needing approval fails immediately rather than holding the sandbox open", %{
    ctx: ctx
  } do
    # No rule, so the layered policy asks. A sandboxed run is bounded in wall clock and a person is
    # not, so the honest answer is an error value now rather than a timeout in a second.
    code = """
    local v, err = trinity.tool("echo", {text = "hi"})
    return tostring(err)
    """

    assert {:ok, [message], stats} = Sandbox.run(code, context: ctx, max_time_ms: 2_000)
    assert is_binary(message)

    assert stats.time_ms < 1_500,
           "the run took #{stats.time_ms}ms, which suggests it waited for a decision rather than " <>
             "returning one"
  end

  test "an unknown tool is a named refusal, not a crash", %{ctx: ctx} do
    code = ~s|local v, err = trinity.tool("no_such_tool", {}) return tostring(err)|
    assert {:ok, [message], _} = Sandbox.run(code, context: ctx)
    assert message =~ "unknown tool"
  end

  describe "the rest of the surface" do
    test "trinity.log collects lines and they come back in the stats", %{ctx: ctx} do
      code = ~s|trinity.log("one") trinity.log("two") return 1|
      assert {:ok, [1], stats} = Sandbox.run(code, context: ctx)
      assert stats.log == ["one", "two"]
    end

    test "trinity.result declares the run's value, replacing the return", %{ctx: ctx} do
      code = ~s|trinity.result({total = 7, ok = true}) return "ignored"|
      assert {:ok, declared, _} = Sandbox.run(code, context: ctx)
      assert {"total", 7} in declared
      assert {"ok", true} in declared
    end

    test "json round-trips an object and an array", %{ctx: ctx} do
      code = ~s|return json.encode({a = 1, b = "two"})|
      assert {:ok, [json], _} = Sandbox.run(code, context: ctx)
      assert Jason.decode!(json) == %{"a" => 1, "b" => "two"}

      code = ~s|local t = json.decode('[10,20,30]') return t[1] + t[3]|
      assert {:ok, [40], _} = Sandbox.run(code, context: ctx)
    end

    test "json.decode of rubbish is a value, not a crash", %{ctx: ctx} do
      code = ~s|local v, err = json.decode("{oh no") return tostring(err)|
      assert {:ok, [message], _} = Sandbox.run(code, context: ctx)
      assert message =~ "not valid JSON"
    end
  end
end
