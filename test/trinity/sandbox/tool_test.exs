# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.ToolTest do
  @moduledoc """
  Slice 110: `run_lua` as the model sees it.

  The behaviour worth pinning is that a **refused run is a result, not a tool error**. A model that
  asks a legitimate question and gets an error ends its turn; one that gets "the script did not
  finish in 200 ms" writes a smaller script. The distinction is the difference between a sandbox
  that is usable and one that is merely safe.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  alias Trinity.Sandbox.Tool
  alias Trinity.Tools.Context

  setup do
    session = Trinity.Factory.session!()
    scope = Trinity.Receipts.session_scope(session.id)
    on_exit(fn -> Trinity.Receipts.stop_writer(scope) end)
    {:ok, ctx: %Context{session_id: session.id, caller: session.id, call_id: "c"}}
  end

  test "the tier is exec and the effect is none, which are different questions" do
    assert Tool.risk() == :exec

    assert Tool.effect() == :none,
           "the script itself reaches nothing; what it wants done it asks for through " <>
             "trinity.tool, which the gate decides again under that tool's own tier"
  end

  test "it is registered under its name and the registry admits it", %{ctx: _} do
    assert {:ok, %{name: "run_lua", risk: :exec, effect: :none}} = Trinity.Tools.lookup("run_lua")
  end

  test "a computation comes back as text with its statistics in the meta", %{ctx: ctx} do
    code = "local s = 0 for i = 1, 100 do s = s + i end return s"
    assert {:ok, result} = Tool.execute(%{"code" => code}, ctx)
    assert result.content =~ "5050"
    assert result.meta["reductions"] > 0
    assert is_integer(result.meta["time_ms"])
  end

  test "log lines are appended under a heading rather than lost", %{ctx: ctx} do
    code = ~s|trinity.log("counting") trinity.log("done") return 1|
    assert {:ok, result} = Tool.execute(%{"code" => code}, ctx)
    assert result.content =~ "-- log --"
    assert result.content =~ "counting"
    assert result.meta["log_lines"] == 2
  end

  test "a run that does not finish is a result explaining why, not a tool error", %{ctx: ctx} do
    assert {:ok, result} =
             Tool.execute(%{"code" => "while true do end", "max_time_ms" => 150}, ctx)

    assert result.content =~ "did not finish within 150 ms"
    assert result.meta["refused"] == true
  end

  test "a script longer than the cap is refused before it runs", %{ctx: ctx} do
    huge = String.duplicate("-- padding\n", 3_000)
    assert {:error, {:script_too_long, _, _}} = Tool.execute(%{"code" => huge}, ctx)
  end

  test "a Lua error explains itself rather than ending the turn", %{ctx: ctx} do
    assert {:ok, result} = Tool.execute(%{"code" => "error('deliberate')"}, ctx)
    assert result.content =~ "raised"
    assert result.meta["refused"] == true
  end

  test "the result is marked untrusted, like any other tool result", %{ctx: ctx} do
    assert {:ok, result} = Tool.execute(%{"code" => "return 1"}, ctx)

    # The mark lives on the parts, not on the result: `Trinity.Tools.Untrusted.result/2` wraps the
    # text into one part and that is what carries the provenance into the prompt.
    assert [part] = result.parts

    assert part.taint == :untrusted,
           "a script's output can be derived from a file or a page, so it re-enters the prompt as " <>
             "data rather than as command: #{inspect(part)}"

    assert part.source_ref == "sandbox"
  end
end
