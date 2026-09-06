# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SmokeTest do
  @moduledoc """
  Slice 001 line 5. The plan pre-registered this red as "a smoke run that stays alive past its
  own exit call", so `halt` is injected and the test asserts it was called. Committed failing
  against a `run/2` that reports the port and returns.

  The end-to-end half of this — the real binary, `ps` before and after — is AC7 and lives in
  PROOF.md. A unit test cannot prove a process died; it can prove this code asked it to.
  """
  use ExUnit.Case, async: false

  alias Trinity.Smoke

  describe "requested?/1" do
    test "true only for the exact flag" do
      assert Smoke.requested?(["--smoke"])
      assert Smoke.requested?(["foo", "--smoke", "bar"])
      refute Smoke.requested?([])
      refute Smoke.requested?(["--smoked"])
      refute Smoke.requested?(["smoke"])
    end
  end

  describe "port_line/1" do
    test "is one key=value pair a shell can cut" do
      line = Smoke.port_line(41_235)
      assert line == "TRINITY_SMOKE_PORT=41235"
      assert [_, "41235"] = String.split(line, "=")
    end
  end

  describe "run/2" do
    test "reports the port the endpoint actually bound" do
      me = self()
      Smoke.run(&send(me, {:said, &1}), fn _ -> :ok end)
      assert_received {:said, line}
      assert line =~ ~r/^TRINITY_SMOKE_PORT=\d+$/
    end

    test "stops the OS process instead of serving forever" do
      me = self()
      Smoke.run(fn _ -> :ok end, &send(me, {:halted, &1}))

      assert_received {:halted, status},
                      "run/2 returned without calling halt: a binary launched with --smoke " <>
                        "would print its port and then serve forever, which is the leak AC7 " <>
                        "exists to catch"

      assert status == 0
    end
  end
end
