# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.ScannerLuaTest do
  @moduledoc """
  Slice 110: the skill scanner flags a Lua script reaching for what the sandbox removes.

  **This is a reviewer's signal, not a control.** The control is that the globals are absent at run
  time, asserted one by one in `sandbox_test.exs`. A regular expression over source text can be got
  around and would be a poor last line; its job is to make sure a person approving a skill is told
  what its script is reaching for.
  """
  use ExUnit.Case, async: true

  alias Trinity.Skills.Scanner

  defp rules(source), do: Scanner.scan_file("s.lua", source) |> Enum.map(& &1.rule)

  test "the rule is registered with its severity" do
    assert {"sandbox_escape", "high"} in Scanner.rules()
  end

  test "each removed global is flagged when called" do
    for call <- [
          "os.execute('id')",
          "os.exit(1)",
          "os.getenv('HOME')",
          "os.remove('/tmp/x')",
          "io.open('/etc/passwd')",
          "io.write('x')",
          "require('socket')",
          "loadstring('return 1')",
          "dofile('/tmp/x.lua')",
          "package.loadlib('a', 'b')"
        ] do
      assert "sandbox_escape" in rules("local x = #{call}"),
             "#{call} did not raise the flag a reviewer needs"
    end
  end

  test "ordinary Lua is not flagged, because a rule that fires on everything is read by nobody" do
    source = """
    local sum = 0
    for _, n in ipairs(args.numbers) do sum = sum + n end
    trinity.log("counted " .. #args.numbers)
    trinity.result({total = sum, when_ = os.time()})
    """

    refute "sandbox_escape" in rules(source),
           "os.time and the host API are what a legitimate script uses; flagging them would train " <>
             "a reviewer to dismiss the rule"
  end

  test "a mention without a call is not flagged" do
    refute "sandbox_escape" in rules("-- this script does not use os.execute at all")
  end
end
