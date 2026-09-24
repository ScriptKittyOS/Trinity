# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects.CensusTest do
  @moduledoc """
  Slice 024 AC1: exactly one caller of `execute/2` for effectful tools, and a planted bypass
  is flagged. The population is every source file in `lib/` and `test/support/` that
  `git ls-files` names, grepped for a call of `execute(` on a module value; the allowed set is
  `Trinity.Authority.Local` (the executor for effectful tools) and `Trinity.Tools.Runner`
  (whose `call_tool/3` is guarded to `effect: :none`, which the second test proves). The
  planted `Trinity.TestEffects.Bypass` is the third name and must be there, or the census is
  not looking.
  """
  use ExUnit.Case, async: true

  alias Trinity.Tools.{Context, Runner}

  # Slice 027 AC1: each allowed caller carries the reason it is allowed, because a bare list of two
  # paths is a claim a reader has to take on trust, and the next person to add a third has nothing
  # to weigh their case against. A path with no reason is not allowed: `@allowed` is a map and the
  # test below asserts every reason is present and says something.
  @allowed %{
    "lib/trinity/authority/local.ex" =>
      "the executor under TRINITY_AUTHORITY=local: the membrane admits an effect and this is what " <>
        "runs the tool's own execute/2. Under an external authority adapter this file is not the " <>
        "executor and the effect never reaches it.",
    "lib/trinity/tools/runner.ex" =>
      "the non-effect path: call_tool/3 is guarded to effect: :none, which the second test in this " <>
        "file proves by calling it with an effectful tool and reading the refusal by name."
  }
  @planted ["test/support/effects/bypass.ex"]

  test "the callers of execute/2 on a tool module are the two allowed and the one planted" do
    {out, 0} = System.cmd("git", ["ls-files", "lib/*.ex", "test/support/*.ex"])
    files = String.split(out, "\n", trim: true)
    assert length(files) > 100

    # `<variable>.execute(` is a call on a module held in a variable, which is how a tool is
    # invoked; `Trinity.Effects.execute(` and `authority.execute(` are the membrane and the
    # authority behaviour, named and excluded by their receivers; `:telemetry.execute(` is an
    # Erlang module, excluded by the colon before it.
    callers =
      for f <- files,
          src = File.read!(f),
          Regex.scan(~r/(?<![:\w])([a-z_]+)\.execute\(/, src)
          |> Enum.map(fn [_, recv] -> recv end)
          |> Enum.reject(&(&1 in ["authority", "impl", "executor"]))
          |> Enum.any?(),
          do: f

    assert Enum.sort(callers) == Enum.sort(Map.keys(@allowed) ++ @planted)
  end

  test "every allowed caller carries a reason, and the reason says something" do
    for {path, reason} <- @allowed do
      assert is_binary(reason) and String.length(reason) > 40,
             "#{path} is allowed to call execute/2 with no reason worth reading. A reader cannot " <>
               "weigh a third caller's case against a list that does not say why the first two are " <>
               "there"
    end
  end

  test "Tools.Runner.call_tool/3 runs an effect: :none entry and refuses an effectful one by name" do
    {:ok, echo} = Trinity.Tools.lookup("echo")
    {:ok, note} = Trinity.Tools.lookup("write_note")
    ctx = %Context{}
    assert {:ok, %{content: "hi"}} = Runner.call_tool(echo, %{"text" => "hi"}, ctx)

    assert {:error, {:effectful_tool_outside_membrane, "write_note"}} =
             Runner.call_tool(note, %{"path" => "/x", "text" => "t"}, ctx)
  end

  test "the planted bypass is a real bypass: it runs the effectful tool, which is what the census exists to catch" do
    assert {:ok, %{content: "wrote 1 bytes to /x"}} =
             Trinity.TestEffects.Bypass.run(
               Trinity.TestTools.WriteNote,
               %{"path" => "/x", "text" => "t"},
               %Context{}
             )
  end
end
