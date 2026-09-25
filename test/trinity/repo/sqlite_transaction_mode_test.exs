# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.SqliteTransactionModeTest do
  @moduledoc """
  Slice 005 AC1: R26's mechanism, reproduced deterministically, and the fix demonstrated against it.

  R26 has been an intermittent failure for two days and five pull requests. An intermittent fault
  that stops appearing is a fault you got lucky with, so this does not run fifty writers and hope:
  it drives two SQLite connections through the exact sequence the risk register describes and
  asserts the error by name.

  **The mechanism.** A `DEFERRED` transaction takes no lock at `BEGIN` and starts as a reader. At its
  first write it tries to upgrade, and if another connection has written since, SQLite returns
  `SQLITE_BUSY` **without invoking the busy handler**, because blocking at that point risks deadlock.
  No `busy_timeout` affects it, which is why raising it from 5 s to 30 s changed nothing.

  **The fix.** `BEGIN IMMEDIATE` takes the write lock at `BEGIN`, where the busy handler is allowed
  to wait.

  These run against their own database file rather than the sandboxed repo, because the sandbox
  wraps each test in one connection's transaction and cannot express two contending writers. What is
  under test is SQLite's locking, not Ecto's.
  """
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3

  setup do
    path = Path.join(System.tmp_dir!(), "r26-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1) end)

    {:ok, setup_conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(setup_conn, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(setup_conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    :ok = Sqlite3.close(setup_conn)

    {:ok, a} = Sqlite3.open(path)
    {:ok, b} = Sqlite3.open(path)
    # Generous, and deliberately so: the point is that it does not help on the upgrade path.
    :ok = Sqlite3.execute(a, "PRAGMA busy_timeout=5000")
    :ok = Sqlite3.execute(b, "PRAGMA busy_timeout=5000")
    on_exit(fn -> Enum.each([a, b], &Sqlite3.close/1) end)

    {:ok, a: a, b: b}
  end

  test "DEFERRED: an upgrade under contention is refused at once, whatever busy_timeout says",
       %{a: a, b: b} do
    :ok = Sqlite3.execute(a, "BEGIN DEFERRED")
    :ok = Sqlite3.execute(a, "SELECT count(*) FROM t")

    :ok = Sqlite3.execute(b, "BEGIN IMMEDIATE")
    :ok = Sqlite3.execute(b, "INSERT INTO t (v) VALUES ('from b')")

    started = System.monotonic_time(:millisecond)
    result = Sqlite3.execute(a, "INSERT INTO t (v) VALUES ('from a')")
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, reason} = result
    message = to_string(inspect(reason))

    assert message =~ "busy" or message =~ "locked",
           "expected a busy error on the upgrade, got #{message}"

    assert elapsed < 1_000,
           "the upgrade waited #{elapsed} ms before failing. It should fail immediately: SQLite " <>
             "does not invoke the busy handler here, which is the whole reason busy_timeout never " <>
             "fixed R26"

    Sqlite3.execute(a, "ROLLBACK")
    Sqlite3.execute(b, "COMMIT")
  end

  test "IMMEDIATE: the same sequence waits on the busy handler instead of failing", %{a: a, b: b} do
    :ok = Sqlite3.execute(b, "BEGIN IMMEDIATE")
    :ok = Sqlite3.execute(b, "INSERT INTO t (v) VALUES ('from b')")

    task = Task.async(fn -> Sqlite3.execute(a, "BEGIN IMMEDIATE") end)
    Process.sleep(100)
    :ok = Sqlite3.execute(b, "COMMIT")

    assert :ok = Task.await(task, 5_000),
           "BEGIN IMMEDIATE was refused rather than waiting, so the busy handler is not being " <>
             "consulted even on the path where it should be"

    assert :ok = Sqlite3.execute(a, "INSERT INTO t (v) VALUES ('from a')")
    :ok = Sqlite3.execute(a, "COMMIT")
  end
end
