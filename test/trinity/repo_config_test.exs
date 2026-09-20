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
    test "has exactly one connection" do
      assert Trinity.Repo.config()[:pool_size] == 1
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

  describe "the receipts repo slot" do
    test "is declared, uses the same adapter, and is not running" do
      assert Trinity.Repo.Receipts.__adapter__() == Trinity.Repo.__adapter__()
      assert Process.whereis(Trinity.Repo.Receipts) == nil
    end
  end
end
