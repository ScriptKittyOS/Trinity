# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SmokeTest do
  @moduledoc """
  Slice 001 line 5. The plan pre-registered this red as "a smoke run that stays alive past its
  own exit call", so `halt` is injected and the test asserts it was called. Committed failing
  against a `run/2` that reports the port and returns.

  The end-to-end half of this (the real binary, `ps` before and after) is AC7 and lives in
  PROOF.md. A unit test cannot prove a process died; it can prove this code asked it to.
  """
  use ExUnit.Case, async: false

  alias Trinity.Smoke

  # Slice 032: the three lines that need the Repo are injected here (SmokeTest has no
  # sandbox); Trinity.Memory.VectorStoreTest proves `Semantic.smoke/0` on a database.
  @rest [
    "TRINITY_SMOKE_EXLA=ok",
    "TRINITY_SMOKE_VEC=ok:Trinity.Memory.VectorStores.Brute",
    "TRINITY_SMOKE_SEMANTIC=on"
  ]

  describe "requested?/1" do
    test "true only for the exact flag" do
      assert Smoke.requested?(["--smoke"])
      assert Smoke.requested?(["foo", "--smoke", "bar"])
      refute Smoke.requested?([])
      refute Smoke.requested?(["--smoked"])
      refute Smoke.requested?(["smoke"])
    end

    # Slice 032: the variable form, which Kernel.CLI cannot mistake for a file.
    test "true with TRINITY_SMOKE=1 and no argument" do
      System.put_env("TRINITY_SMOKE", "1")
      on_exit(fn -> System.delete_env("TRINITY_SMOKE") end)
      assert Smoke.requested?([])
      assert Smoke.probe([]) == [Trinity.Smoke.Probe]
      System.put_env("TRINITY_SMOKE", "0")
      refute Smoke.requested?([])
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
    test "reports the port the endpoint actually bound, not the one it was configured with" do
      configured = Application.get_env(:trinity, TrinityWeb.Endpoint)[:http][:port]

      assert configured == 0,
             "this test only means something against an ephemeral bind; configured port is " <>
               "#{inspect(configured)}. runtime.exs overrode it with 4000 once already."

      me = self()
      Smoke.run(&send(me, {:said, &1}), fn _ -> :ok end, Smoke.markdown_line(), @rest)
      assert_received {:said, line}
      assert [_, reported] = String.split(line, "=")
      reported = String.to_integer(reported)

      assert reported != 0,
             "run/2 echoed the configured 0 instead of asking the endpoint what it got"

      assert {:ok, {_ip, ^reported}} = TrinityWeb.Endpoint.server_info(:http)
    end

    test "stops the OS process instead of serving forever" do
      me = self()
      Smoke.run(fn _ -> :ok end, &send(me, {:halted, &1}), Smoke.markdown_line(), @rest)

      assert_received {:halted, status},
                      "run/2 returned without calling halt: a binary launched with --smoke " <>
                        "would print its port and then serve forever, which is the leak AC7 " <>
                        "exists to catch"

      assert status == 0
    end

    # Slice 013: a packaged binary whose markdown NIF does not load still boots and serves
    # (NOTES.md finding 13), so the smoke path says whether it rendered, and exits 3 if not.
    test "says whether the markdown renderer rendered, on its own line" do
      me = self()
      Smoke.run(&send(me, {:said, &1}), &send(me, {:halted, &1}), Smoke.markdown_line(), @rest)
      assert_received {:said, "TRINITY_SMOKE_PORT=" <> _}
      assert_received {:said, "TRINITY_SMOKE_MARKDOWN=ok"}
      assert_received {:said, "TRINITY_SMOKE_EXLA=ok"}
      assert_received {:said, "TRINITY_SMOKE_VEC=ok:" <> _}
      assert_received {:said, "TRINITY_SMOKE_SEMANTIC=on"}
      assert_received {:halted, 0}
      assert Smoke.markdown_line() == "TRINITY_SMOKE_MARKDOWN=ok"
    end

    # Slice 032, AC7: the vector search is binding (exit 4), the EXLA and status lines are not.
    test "exits 4 when the vector search inside the binary fails; a failed EXLA line alone still exits 0" do
      me = self()

      failed = [
        "TRINITY_SMOKE_EXLA=failed:x",
        "TRINITY_SMOKE_VEC=failed:y",
        "TRINITY_SMOKE_SEMANTIC=off:z"
      ]

      Smoke.run(fn _ -> :ok end, &send(me, {:halted, &1}), Smoke.markdown_line(), failed)
      assert_received {:halted, 4}

      Smoke.run(fn _ -> :ok end, &send(me, {:halted, &1}), Smoke.markdown_line(), [
        "TRINITY_SMOKE_EXLA=failed:x",
        "TRINITY_SMOKE_VEC=ok:S",
        "TRINITY_SMOKE_SEMANTIC=off:z"
      ])

      assert_received {:halted, 0}
    end

    test "the EXLA line on this machine (the NIF is compiled and loads here; the bundle's answer is AC7's)" do
      assert Smoke.exla_line() == "TRINITY_SMOKE_EXLA=ok"
      assert Smoke.semantic_line() == "TRINITY_SMOKE_SEMANTIC=on"
    end
  end
end
