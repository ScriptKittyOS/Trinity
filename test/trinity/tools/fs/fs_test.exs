# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FSTest do
  @moduledoc "Slice 022 AC1 to AC4 and the filesystem tools' shapes, in a temporary directory that is a root."
  use Trinity.DataCase, async: false

  alias Trinity.Permissions
  alias Trinity.Tools.{Context, FS}
  alias Trinity.Tools.FS.{Edit, Glob, Grep, List, Placeholders, Read, Write}

  setup do
    dir = Path.join(System.tmp_dir!(), "trinity-fs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:trinity, :fs, [])
    Application.put_env(:trinity, :fs, Keyword.put(previous, :roots, [dir]))

    on_exit(fn ->
      Application.put_env(:trinity, :fs, previous)
      File.rm_rf!(dir)
      File.rm_rf!(FS.backup_dir(Path.join(dir, "a.txt")))
    end)

    {:ok, dir: dir, ctx: %Context{session_id: nil, cwd: dir}}
  end

  describe "AC1: the roots" do
    test "a read inside the roots answers content; outside it escalates to :ask, and the gate says :ask",
         %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree\n")
      assert {:ok, result} = Read.execute(%{"path" => "a.txt"}, ctx)
      assert result.content == "1\tone\n2\ttwo\n3\tthree\n4\t"
      assert [%{taint: :untrusted, origin: "tool:fs_read"}] = result.parts
      assert Read.escalate(%{"path" => "a.txt"}, ctx) == nil

      outside =
        Path.join(System.tmp_dir!(), "trinity-outside-#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "secret")
      on_exit(fn -> File.rm(outside) end)
      assert Read.escalate(%{"path" => outside}, ctx) == :ask
      assert Permissions.decide(nil, "fs_read", %{"path" => outside}, escalate: :ask) == :ask
      assert Permissions.decide(nil, "fs_read", %{"path" => "a.txt"}, escalate: nil) == :allow
    end

    test "a symlink pointing outside the roots resolves outside", %{dir: dir, ctx: ctx} do
      outside_dir =
        Path.join(System.tmp_dir!(), "trinity-out-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      on_exit(fn -> File.rm_rf!(outside_dir) end)
      File.ln_s!(outside_dir, Path.join(dir, "link"))
      assert {:ok, _, :outside} = FS.resolve("link/x.txt", dir)
      assert Read.escalate(%{"path" => "link/x.txt"}, ctx) == :ask
      assert {:ok, _, :inside} = FS.resolve("new/file.txt", dir)
    end

    test "an escalation can only raise the tier" do
      assert Permissions.effective_tier("fs_read", :ask) == :ask
      assert Permissions.effective_tier("fs_write", :read) == :write
      assert Permissions.effective_tier("fs_write", nil) == :write
    end
  end

  describe "AC2: the write-validation hook" do
    @truncated "defmodule X do\n  def a, do: 1\n  // ... rest of file\nend\n"

    test "content with a truncation marker is refused with the line named", %{ctx: ctx} do
      assert {:error, {:placeholders, message}} =
               Write.execute(%{"path" => "x.ex", "content" => @truncated}, ctx)

      assert message =~ "line 3"
      assert message =~ "allow_placeholders"
      refute File.exists?(Path.join(ctx.cwd, "x.ex"))

      assert {:error, {:placeholders, _}} =
               Write.execute(%{"path" => "y.c", "content" => "int a;\n/* ... */\n"}, ctx)
    end

    test "the same content with allow_placeholders escalates to :destructive, and then writes", %{
      ctx: ctx
    } do
      args = %{"path" => "x.ex", "content" => @truncated, "allow_placeholders" => true}
      assert Write.escalate(args, ctx) == :destructive
      assert Permissions.decide(nil, "fs_write", args, escalate: :destructive) == :ask
      assert {:ok, result} = Write.execute(args, ctx)
      assert result.meta["new"] == true
      assert File.read!(Path.join(ctx.cwd, "x.ex")) == @truncated
    end

    test "the marker list" do
      assert [{1, _}] = Placeholders.find("# ... rest unchanged")
      assert [{2, _}] = Placeholders.find("a\n...\nb")
      assert [{1, _}] = Placeholders.find("rest of the file unchanged")
      assert Placeholders.find("x = 1 # not a marker\ny = [1, 2, 3]") == []
    end
  end

  describe "AC3: atomic writes and the backup ring" do
    test "a write replaces the file whole, keeps a backup, and restore/2 brings the previous version back",
         %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "a.txt")
      assert {:ok, r1} = Write.execute(%{"path" => "a.txt", "content" => "v1\n"}, ctx)
      assert r1.artifacts == []
      assert {:ok, r2} = Write.execute(%{"path" => "a.txt", "content" => "v2\n"}, ctx)
      assert [%{"kind" => "backup", "path" => backup}] = r2.artifacts
      assert File.read!(backup) == "v1\n"
      assert File.read!(path) == "v2\n"

      refute Enum.any?(File.ls!(dir), &String.ends_with?(&1, ".tmp")),
             "no temporary file left behind"

      assert {:ok, _} = FS.restore(path)
      assert File.read!(path) == "v1\n"
      # The restore backed up v2 first, so the ring now holds both.
      assert length(FS.backups(path)) == 2

      for n <- 3..9,
          do: {:ok, _} = Write.execute(%{"path" => "a.txt", "content" => "v#{n}\n"}, ctx)

      assert length(FS.backups(path)) == 5, "the ring keeps the last five"
    end
  end

  describe "AC4: edit" do
    test "a unique search is replaced and a diff comes back; an absent or ambiguous one is refused",
         %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "e.txt"), "alpha\nbeta\ngamma\nbeta\n")

      assert {:error, {:edit, msg}} =
               Edit.execute(%{"path" => "e.txt", "search" => "beta", "replace" => "B"}, ctx)

      assert msg =~ "2 times"

      assert {:error, {:edit, msg}} =
               Edit.execute(%{"path" => "e.txt", "search" => "delta", "replace" => "D"}, ctx)

      assert msg =~ "not found"

      assert {:ok, result} =
               Edit.execute(
                 %{"path" => "e.txt", "search" => "alpha\nbeta", "replace" => "alpha\nBETA"},
                 ctx
               )

      assert File.read!(Path.join(dir, "e.txt")) == "alpha\nBETA\ngamma\nbeta\n"
      assert result.content =~ "-beta" and result.content =~ "+BETA" and result.content =~ "--- "
      assert [%{"kind" => "backup"}] = result.artifacts

      assert {:error, {:placeholders, _}} =
               Edit.execute(
                 %{"path" => "e.txt", "search" => "gamma", "replace" => "// ... rest"},
                 ctx
               )
    end
  end

  describe "list, glob, grep" do
    test "each answers an untrusted part and respects the roots", %{dir: dir, ctx: ctx} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "sub/one.ex"), "defmodule One do\nend\n")
      File.write!(Path.join(dir, "two.md"), "# Two\nhello world\n")
      assert {:ok, l} = List.execute(%{}, ctx)
      assert l.content =~ "d\t-\tsub/" and l.content =~ "two.md"
      assert {:ok, g} = Glob.execute(%{"pattern" => "**/*.ex"}, ctx)
      assert g.content == "sub/one.ex"
      assert {:ok, r} = Grep.execute(%{"pattern" => "hello"}, ctx)
      assert r.content == "two.md:2: hello world"
      assert {:error, {:regex, _}} = Grep.execute(%{"pattern" => "["}, ctx)

      for {m, t} <- [{l, "fs_list"}, {g, "fs_glob"}, {r, "fs_grep"}],
          do: assert([%{origin: "tool:" <> ^t, taint: :untrusted}] = m.parts)

      assert List.escalate(%{"path" => "/"}, ctx) == :ask
    end
  end
end
