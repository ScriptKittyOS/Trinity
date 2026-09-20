# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.DataDir.LockTest do
  @moduledoc """
  Slice 010 AC6: a second instance against a held data dir refuses to start, names the
  holder's pid and mode, and leaves the database untouched.
  """
  use ExUnit.Case, async: true

  alias Trinity.DataDir.Lock

  setup do
    dir = Path.join(System.tmp_dir!(), "trinity-lock-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "the first acquire wins and the file names this OS pid and the mode", %{dir: dir} do
    assert {:ok, holder} = Lock.acquire(dir, :desktop)
    assert holder.pid == String.to_integer(System.pid())
    assert holder.mode == :desktop
    assert {:ok, ^holder} = Lock.holder(dir)
  end

  test "a second acquire in the same VM is refused, naming the live holder", %{dir: dir} do
    assert {:ok, holder} = Lock.acquire(dir, :desktop)
    assert {:error, {:held, ^holder}} = Lock.acquire(dir, :headless)
  end

  test "the supervised child refuses to start against a held dir with pid and mode in the reason",
       %{dir: dir} do
    assert {:ok, holder} = Lock.acquire(dir, :desktop)
    Process.flag(:trap_exit, true)

    assert {:error, {:data_dir_held, message}} =
             Lock.start_link(
               dir: dir,
               mode: :headless,
               name: :"lock-test-#{System.unique_integer()}"
             )

    assert message =~ "OS pid #{holder.pid}"
    assert message =~ "desktop mode"
    assert message =~ "touching no database file"
  end

  test "a held dir has no database file created by the refused instance", %{dir: dir} do
    assert {:ok, _} = Lock.acquire(dir, :desktop)
    Process.flag(:trap_exit, true)

    assert {:error, _} =
             Lock.start_link(
               dir: dir,
               mode: :headless,
               name: :"lock-test-#{System.unique_integer()}"
             )

    assert File.ls!(dir) == ["LOCK"]
  end

  test "a stale file from a dead pid is taken over (linux liveness through /proc)", %{dir: dir} do
    File.mkdir_p!(dir)
    # 4194304 is above Linux's default pid_max, so no live process carries it.
    File.write!(
      Path.join(dir, "LOCK"),
      "pid 4194304\nmode headless\ntoken stale\nat 2026-09-20T00:00:00Z\n"
    )

    case :os.type() do
      {:unix, :linux} ->
        assert {:ok, holder} = Lock.acquire(dir, :desktop)
        assert holder.mode == :desktop
        assert {:ok, ^holder} = Lock.holder(dir)

      _ ->
        assert {:error, {:held, %{pid: 4_194_304}}} = Lock.acquire(dir, :desktop)
    end
  end

  test "a malformed file is treated as held, never taken over silently", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "LOCK"), "garbage")
    assert {:error, {:held, %{mode: :unknown}}} = Lock.acquire(dir, :desktop)
    assert File.read!(Path.join(dir, "LOCK")) == "garbage"
  end

  test "release removes the file only for the token that wrote it", %{dir: dir} do
    assert {:ok, holder} = Lock.acquire(dir, :desktop)
    assert :ok = Lock.release(dir, %{holder | token: "someone-else"})
    assert File.exists?(Path.join(dir, "LOCK"))
    assert :ok = Lock.release(dir, holder)
    refute File.exists?(Path.join(dir, "LOCK"))
  end

  test "the child releases on terminate", %{dir: dir} do
    {:ok, pid} =
      Lock.start_link(dir: dir, mode: :desktop, name: :"lock-test-#{System.unique_integer()}")

    assert File.exists?(Path.join(dir, "LOCK"))
    :ok = GenServer.stop(pid)
    refute File.exists?(Path.join(dir, "LOCK"))
  end
end
