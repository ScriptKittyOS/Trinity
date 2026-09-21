# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.ImportTaskTest do
  @moduledoc "Slice 034: the import task refuses a held data directory and a non-empty one, and restores into an empty one."
  use ExUnit.Case, async: false

  alias Trinity.Archive
  alias Trinity.Archive.Layout

  setup do
    tmp = Path.join(System.tmp_dir!(), "trinity-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    archive = Path.join(tmp, "a.tar.gz")
    {:ok, _} = Archive.export(Layout.current(), archive)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    {:ok, tmp: tmp, archive: archive}
  end

  test "a directory held by a live process is refused before anything else", %{
    tmp: tmp,
    archive: archive
  } do
    held = Path.join(tmp, "held")
    File.mkdir_p!(held)
    {:ok, _holder} = Trinity.DataDir.Lock.acquire(held, :desktop)

    assert catch_exit(Mix.Tasks.Trinity.Import.run([archive, "--data-dir", held])) ==
             {:shutdown, 1}

    assert_received {:mix_shell, :error, [msg]}
    assert msg =~ "holds #{held}; stop it first"
    assert File.ls!(held) == ["LOCK"]
  end

  test "an empty directory is restored and the task says what it wrote; a second run is refused, --force replaces",
       %{tmp: tmp, archive: archive} do
    dir = Path.join(tmp, "fresh")
    Mix.Tasks.Trinity.Import.run([archive, "--data-dir", dir])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "restored 3 files from #{archive}"
    assert File.exists?(Path.join(dir, "trinity.db"))
    assert File.exists?(Path.join(dir, "RESTORED"))

    assert catch_exit(Mix.Tasks.Trinity.Import.run([archive, "--data-dir", dir])) ==
             {:shutdown, 1}

    assert_received {:mix_shell, :error, [msg]}
    assert msg =~ "is not empty"

    Mix.Tasks.Trinity.Import.run([archive, "--data-dir", dir, "--force"])
    assert_received {:mix_shell, :info, ["replaced " <> _]}
  end

  test "usage without an archive is exit 2" do
    assert catch_exit(Mix.Tasks.Trinity.Import.run([])) == {:shutdown, 2}
    assert catch_exit(Mix.Tasks.Trinity.Export.run([])) == {:shutdown, 2}
  end
end
