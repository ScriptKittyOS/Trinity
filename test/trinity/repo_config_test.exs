# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.RepoConfigTest do
  @moduledoc """
  Slice 010 line 2. The pragmas config/config.exs names are read back from a live connection,
  so a default change upstream or a typo in the config key is a red here and not a silent
  behaviour change. SQLite only; the Postgres matrix job excludes this module by tag.
  """
  use Trinity.DataCase, async: false

  @moduletag :sqlite

  describe "the write pool" do
    # Slice 050: the shipped configuration is read from the file under the production
    # environment, since the suite's own pool has two connections (config/test.exs says why:
    # Oban verifies its migration at boot through a raw checkout while a boot process holds
    # the sandbox's first connection in auto mode). What every test still gets is one
    # connection shared with every process it starts.
    test "has exactly one connection in the shipped configuration" do
      config = Config.Reader.read!("config/config.exs", env: :prod)
      assert config[:trinity][Trinity.Repo][:pool_size] == 1
      assert config[:trinity][Trinity.Repo.Receipts][:pool_size] == 1
    end
  end

  describe "pragmas read back from the connection" do
    test "journal_mode is wal" do
      assert %{rows: [["wal"]]} = Trinity.Repo.query!("PRAGMA journal_mode")
    end

    test "synchronous is normal (1)" do
      assert %{rows: [[1]]} = Trinity.Repo.query!("PRAGMA synchronous")
    end

    test "foreign_keys are on (1)" do
      assert %{rows: [[1]]} = Trinity.Repo.query!("PRAGMA foreign_keys")
    end

    test "busy_timeout is the configured 5000 ms, and the pragma cannot show it" do
      # exqlite installs its own busy handler through sqlite3_busy_handler and applies the
      # timeout with sqlite3_busy_timeout on its side of that handler, so `PRAGMA busy_timeout`
      # reads 0 on every connection it opens (deps/exqlite/lib/exqlite/connection.ex, the
      # comment above set_busy_timeout/2, at the locked 0.40.0). The config value is the one
      # the driver applies; contention itself is exercised by the slice 010 stress test.
      assert Trinity.Repo.config()[:busy_timeout] == 5000
      assert %{rows: [[0]]} = Trinity.Repo.query!("PRAGMA busy_timeout")
    end

    test "wal_autocheckpoint is the configured 1000 pages" do
      assert %{rows: [[1000]]} = Trinity.Repo.query!("PRAGMA wal_autocheckpoint")
    end
  end

  describe "the receipts repo" do
    # Slice 010 asserted the slot was declared and not running; slice 024 starts it. The
    # 010 assertion is superseded here, not kept beside a contradicting one.
    test "is running on the same adapter, in its own file, with synchronous full and one connection" do
      assert Trinity.Repo.Receipts.__adapter__() == Trinity.Repo.__adapter__()
      assert is_pid(Process.whereis(Trinity.Repo.Receipts))
      assert Trinity.Repo.Receipts.config()[:database] != Trinity.Repo.config()[:database]
      assert Trinity.Repo.Receipts.config()[:pool_size] == 1
      assert %{rows: [["wal"]]} = Trinity.Repo.Receipts.query!("PRAGMA journal_mode")
      # 2 is FULL.
      assert %{rows: [[2]]} = Trinity.Repo.Receipts.query!("PRAGMA synchronous")
    end

    test "its migrations are its own: the receipts tables exist there and not in the primary" do
      assert %{rows: [[1]]} =
               Trinity.Repo.Receipts.query!(
                 "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'receipts'"
               )

      assert %{rows: [[0]]} =
               Trinity.Repo.query!(
                 "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'receipts'"
               )
    end
  end
end
