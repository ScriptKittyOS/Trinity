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
  # Slice 100 appends the three AC9 lines; they are computed by the probe the same way.
  @rest [
    "TRINITY_SMOKE_EXLA=ok",
    "TRINITY_SMOKE_VEC=ok:Trinity.Memory.VectorStores.Brute",
    "TRINITY_SMOKE_SEMANTIC=on",
    "TRINITY_SMOKE_FTS5=ok",
    "TRINITY_SMOKE_WATCHER=ok:fs_inotify",
    "TRINITY_SMOKE_MODEL_CACHE=ok:/tmp/models"
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

      Smoke.run(
        fn _ -> :ok end,
        &send(me, {:halted, &1}),
        Smoke.markdown_line(),
        failed ++ Enum.drop(@rest, 3)
      )

      assert_received {:halted, 4}

      Smoke.run(
        fn _ -> :ok end,
        &send(me, {:halted, &1}),
        Smoke.markdown_line(),
        [
          "TRINITY_SMOKE_EXLA=failed:x",
          "TRINITY_SMOKE_VEC=ok:S",
          "TRINITY_SMOKE_SEMANTIC=off:z"
        ] ++ Enum.drop(@rest, 3)
      )

      assert_received {:halted, 0}
    end

    # Slice 100, AC9: the packaged-binary checks the slice names. FTS5 and the model cache are
    # binding (exit 5 and 6); the watcher is informative, because the skills registry already
    # falls back to polling where no native backend runs, and the line says which it got.
    test "AC9: says whether FTS5, the file watcher and the model cache work, each on its own line" do
      me = self()
      Smoke.run(&send(me, {:said, &1}), &send(me, {:halted, &1}), Smoke.markdown_line(), @rest)
      assert_received {:said, "TRINITY_SMOKE_FTS5=ok"}
      assert_received {:said, "TRINITY_SMOKE_WATCHER=ok:fs_inotify"}
      assert_received {:said, "TRINITY_SMOKE_MODEL_CACHE=ok:/tmp/models"}
      assert_received {:halted, 0}
    end

    test "AC9: exits 5 when FTS5 is missing and 6 when the model cache does not resolve; a watcher fallback alone still exits 0" do
      me = self()
      [exla, vec, sem | _] = @rest
      halt = &send(me, {:halted, &1})
      quiet = fn _ -> :ok end

      Smoke.run(quiet, halt, Smoke.markdown_line(), [
        exla,
        vec,
        sem,
        "TRINITY_SMOKE_FTS5=failed:no such module: fts5",
        "TRINITY_SMOKE_WATCHER=ok:fs_inotify",
        "TRINITY_SMOKE_MODEL_CACHE=ok:/tmp/models"
      ])

      assert_received {:halted, 5}

      Smoke.run(quiet, halt, Smoke.markdown_line(), [
        exla,
        vec,
        sem,
        "TRINITY_SMOKE_FTS5=ok",
        "TRINITY_SMOKE_WATCHER=ok:fs_inotify",
        "TRINITY_SMOKE_MODEL_CACHE=failed:eacces"
      ])

      assert_received {:halted, 6}

      Smoke.run(quiet, halt, Smoke.markdown_line(), [
        exla,
        vec,
        sem,
        "TRINITY_SMOKE_FTS5=ok",
        "TRINITY_SMOKE_WATCHER=fallback:fs_poll",
        "TRINITY_SMOKE_MODEL_CACHE=ok:/tmp/models"
      ])

      assert_received {:halted, 0}
    end

    test "AC9: the three lines measured on this machine" do
      assert Smoke.fts5_line() == "TRINITY_SMOKE_FTS5=ok"
      assert "TRINITY_SMOKE_WATCHER=" <> watcher = Smoke.watcher_line()
      assert watcher =~ ~r/^(ok|fallback):fs_(inotify|poll|mac|windows)/
      assert "TRINITY_SMOKE_MODEL_CACHE=ok:" <> dir = Smoke.model_cache_line()
      assert File.dir?(dir)
    end

    test "the EXLA line on this machine (the NIF is compiled and loads here; the bundle's answer is AC7's)" do
      assert Smoke.exla_line() == "TRINITY_SMOKE_EXLA=ok"
      # Slice 133: the semantic line reads the store's active space, so it needs the database;
      # Trinity.Memory.VectorStoreTest asserts it through the probe, under the sandbox.
    end
  end
end
