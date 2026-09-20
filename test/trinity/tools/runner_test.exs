# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.RunnerTest do
  @moduledoc """
  Slice 020 AC2 to AC7 through a Session: the fake provider emits the tool calls, the Session's
  turn runs them through `Trinity.Tools.Runner`, and the rows say what happened.
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  import Mox

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Tools
  alias Trinity.Tools.Registry

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)

    on_exit(fn ->
      for %{kind: :dynamic, name: n} <- Registry.list(), do: Registry.unregister(n)
    end)

    {:ok, id: row.id}
  end

  # A script that calls the given tools in one turn, then a script with a final answer.
  defp tool_turn(calls) do
    starts = for {id, name, _} <- calls, do: {:tool_call_start, id, name}
    ends = for {id, _, args} <- calls, do: {:tool_call_end, id, args}

    Fake.scripts([
      starts ++ ends ++ [{:usage, %{input_tokens: 1, output_tokens: 1}}, {:done, :tool_calls}],
      script_deltas(2, "done ")
    ])
  end

  defp run_turn(id) do
    {:ok, pid} = start_drained(id)
    {t, {:ok, _}} = :timer.tc(fn -> Session.send_user_message(pid, "go") end)
    _ = t
    started = System.monotonic_time(:millisecond)
    events = collect(id, &match?({:state, :idle}, &1), 10_000)
    elapsed = System.monotonic_time(:millisecond) - started
    {events, elapsed, Sessions.history(id)}
  end

  defp tool_rows(history), do: Enum.filter(history, &(&1.role == "tool"))

  test "AC2: two calls in one turn run concurrently; two tool rows; a final assistant message", %{
    id: id
  } do
    tool_turn([{"c1", "sleep", %{"ms" => 300}}, {"c2", "sleep", %{"ms" => 300}}])
    {events, elapsed, history} = run_turn(id)
    assert :tool_wait in for({:state, s} <- events, do: s)
    assert elapsed < 500, "two 300 ms sleeps took #{elapsed} ms: not concurrent"
    assert Enum.map(history, & &1.role) == ["user", "assistant", "tool", "tool", "assistant"]
    [t1, t2] = tool_rows(history)
    assert t1.tool_call_id == "c1" and t2.tool_call_id == "c2"
    assert t1.content == "slept 300" and t1.parts["ok"] == true
    assert t1.parts["tool_result"]["content"] == "slept 300"

    assert t1.parts["tool_definition_digest"] ==
             Registry.definition_digest(Trinity.TestTools.Sleep)

    assert List.last(history).content == "done done "
  end

  test "AC3: a crashing tool is an error row; the session goes on; no supervisor restart", %{
    id: id
  } do
    sup = Process.whereis(Trinity.Sessions.Supervisor)
    tools_sup = Process.whereis(Trinity.Tools.Supervisor)

    tool_turn([
      {"c1", "crash", %{}},
      {"c2", "crash", %{"how" => "exit"}},
      {"c3", "echo", %{"text" => "still here"}}
    ])

    {_events, _elapsed, history} = run_turn(id)

    assert Enum.map(history, & &1.role) == [
             "user",
             "assistant",
             "tool",
             "tool",
             "tool",
             "assistant"
           ]

    [raised, exited, echoed] = tool_rows(history)
    assert raised.parts["ok"] == false and raised.content =~ "crashed on purpose"
    assert exited.parts["ok"] == false and exited.content =~ "crashed"
    assert echoed.content == "still here"
    assert Process.whereis(Trinity.Sessions.Supervisor) == sup
    assert Process.whereis(Trinity.Tools.Supervisor) == tools_sup
    assert Sessions.whereis(id) != nil
    {:ok, _} = Session.send_user_message(Sessions.whereis(id), "again")
    _ = collect(id, &match?({:assistant_message, _}, &1))
  end

  test "AC4: a tool past its timeout is a timeout row within timeout + 100 ms", %{id: id} do
    tool_turn([{"c1", "sleep", %{"ms" => 5_000}}])
    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "go")
    _ = collect(id, &match?({:state, :tool_wait}, &1))
    started = System.monotonic_time(:millisecond)
    _ = collect(id, &match?({:state, :thinking}, &1), 3_000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed <= 500 + 100, "the timeout row came after #{elapsed} ms"
    _ = collect(id, &match?({:state, :idle}, &1))
    [row] = tool_rows(Sessions.history(id))
    assert row.content == "error: the tool timed out"
    assert row.parts["tool_result"]["error"] == "the tool timed out"
  end

  test "AC5: a result over the cap is truncated in the row with the marker and the original size",
       %{id: id} do
    tool_turn([{"c1", "big", %{}}])
    {_events, _elapsed, history} = run_turn(id)
    [row] = tool_rows(history)
    assert row.parts["tool_result"]["truncated"] == true
    assert row.parts["tool_result"]["meta"]["original_bytes"] == Tools.Result.cap_bytes() * 2
    assert String.ends_with?(row.content, "[truncated: the tool returned more than the cap]")
    assert byte_size(row.content) < Tools.Result.cap_bytes() + 100
  end

  test "AC6: invalid arguments are refused before execute/2 is called", %{id: id} do
    Trinity.Tools.ToolMock
    |> stub(:name, fn -> "mcp:mock:strict" end)
    |> stub(:description, fn -> "A mocked tool." end)
    |> stub(:schema, fn -> Trinity.TestTools.Echo.schema() end)
    |> stub(:risk, fn -> :read end)
    |> stub(:effect, fn -> :none end)
    # Mox defines the optional callbacks too, so the runner sees a timeout/0 and asks it.
    |> stub(:timeout, fn -> 1_000 end)
    |> expect(:execute, 0, fn _, _ -> flunk("execute/2 was called on invalid arguments") end)

    {:ok, _} = Tools.register(Trinity.Tools.ToolMock)
    tool_turn([{"c1", "mcp:mock:strict", %{"text" => 42, "extra" => true}}])
    {_events, _elapsed, history} = run_turn(id)
    [row] = tool_rows(history)
    assert row.parts["ok"] == false
    assert row.content =~ "invalid arguments"
    assert row.content =~ "text"
  end

  test "AC7: Permissions.decide/3 is invoked exactly once per tool call", %{id: id} do
    Application.put_env(:trinity, :permissions_policy, Trinity.Permissions.PolicyMock)
    on_exit(fn -> Application.delete_env(:trinity, :permissions_policy) end)

    Trinity.Permissions.PolicyMock
    |> expect(:decide, 2, fn ^id, name, %{"text" => _}, _opts when name == "echo" -> :allow end)

    tool_turn([{"c1", "echo", %{"text" => "a"}}, {"c2", "echo", %{"text" => "b"}}])
    {_events, _elapsed, history} = run_turn(id)
    assert Enum.map(tool_rows(history), & &1.content) == ["a", "b"]
  end

  test "a denied call is an error row and execute/2 is not reached", %{id: id} do
    Application.put_env(:trinity, :permissions_policy, Trinity.Permissions.PolicyMock)
    on_exit(fn -> Application.delete_env(:trinity, :permissions_policy) end)
    expect(Trinity.Permissions.PolicyMock, :decide, fn _, "crash", _, _ -> :deny end)
    tool_turn([{"c1", "crash", %{}}])
    {_events, _elapsed, history} = run_turn(id)
    [row] = tool_rows(history)
    assert row.content == "error: :denied"
  end

  test "the declared surface is on the assistant row, and the fake's undeclared call is a surface_diff finding",
       %{id: id} do
    tool_turn([{"c1", "echo", %{"text" => "x"}}, {"c2", "get_weather", %{"city" => "Paris"}}])
    {_events, _elapsed, history} = run_turn(id)
    first = Enum.at(history, 1)
    assert first.provider_meta["tool_surface"] == Tools.surface()

    assert Map.keys(first.provider_meta["tool_surface"]) == [
             "big",
             "crash",
             "echo",
             "sleep",
             "write_note"
           ]

    assert Tools.surface_diff(history) == [%{seq: 2, name: "get_weather", reason: :undeclared}]
  end
end
