# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.GuardTest do
  @moduledoc """
  Slice 135: `Trinity.Tools.FS.Guard`'s rules one at a time, in a temporary production layout
  (`XDG_DATA_HOME`, `TRINITY_SECRETS_DIR`), so each refusal is shown with the rule that made it.
  The end-to-end routes are `SecretsReachTest` and the census.
  """
  use ExUnit.Case, async: false

  alias Trinity.Tools.FS.Guard

  @env ["XDG_DATA_HOME", "TRINITY_SECRETS_DIR"]

  setup do
    base = Path.join(System.tmp_dir!(), "s135g-#{System.unique_integer([:positive])}")
    xdg = Path.join(base, "xdg")
    secrets = Path.join(base, "secrets")
    root = Path.join(base, "root")
    Enum.each([xdg, secrets, root], &File.mkdir_p!/1)

    saved_env = Map.new(@env, &{&1, System.get_env(&1)})
    saved_fs = Application.get_env(:trinity, :fs, [])
    System.put_env("XDG_DATA_HOME", xdg)
    System.put_env("TRINITY_SECRETS_DIR", secrets)
    Application.put_env(:trinity, :fs, Keyword.put(saved_fs, :roots, [root]))

    on_exit(fn ->
      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Application.put_env(:trinity, :fs, saved_fs)
      File.rm_rf!(base)
    end)

    {:ok, base: base, root: root, secrets: secrets, data: Path.join(xdg, "trinity")}
  end

  describe "check_roots/2 (AC2's rule)" do
    test "equal, ancestor and descendant of either directory are refused by name; a sibling is not",
         %{base: base} do
      protected = [data_dir: Path.join(base, "d/trinity"), secrets_dir: Path.join(base, "s/x")]

      assert {:error, {:fs_root_overlaps, _, :data_dir, :equal}} =
               Guard.check_roots([Path.join(base, "d/trinity")], protected)

      assert {:error, {:fs_root_overlaps, _, :data_dir, :ancestor}} =
               Guard.check_roots([Path.join(base, "d")], protected)

      assert {:error, {:fs_root_overlaps, _, :data_dir, :descendant}} =
               Guard.check_roots([Path.join(base, "d/trinity/skills")], protected)

      assert {:error, {:fs_root_overlaps, _, :secrets_dir, :ancestor}} =
               Guard.check_roots([Path.join(base, "s")], protected)

      assert {:error, {:fs_root_overlaps, "/", :data_dir, :ancestor}} =
               Guard.check_roots(["/"], protected)

      assert :ok = Guard.check_roots([Path.join(base, "d/trinity-other")], protected)
    end

    test "a root spelled through a symlink is compared in canonical form", %{base: base} do
      File.mkdir_p!(Path.join(base, "real/trinity"))
      File.ln_s!(Path.join(base, "real"), Path.join(base, "alias"))
      protected = [data_dir: Path.join(base, "real/trinity"), secrets_dir: "/nonexistent-s135"]

      assert {:error, {:fs_root_overlaps, _, :data_dir, :ancestor}} =
               Guard.check_roots([Path.join(base, "alias")], protected)
    end

    test "at call time an overlapping root is not a root", %{data: data} do
      File.mkdir_p!(data)
      Application.put_env(:trinity, :fs, roots: [data])
      assert Guard.roots() == []
    end
  end

  describe "check/4" do
    test "inside a root: allowed, with the root and the file's inode", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "a")
      v = Guard.check("a.txt", root, :read)
      assert %{decision: :allow, root: ^root, rule: nil, nlink: 1, type: :regular} = v
      assert v.canonical == Path.join(root, "a.txt")
      assert is_integer(v.ino)
    end

    test "outside every root: asks", %{base: base, root: root} do
      File.write!(Path.join(base, "out.txt"), "o")
      assert %{decision: :ask, root: nil} = Guard.check(Path.join(base, "out.txt"), root, :read)
    end

    test "/proc and /dev are refused", %{root: root} do
      assert %{decision: :deny, rule: "proc_or_dev"} =
               Guard.check("/proc/self/environ", root, :read)

      assert %{decision: :deny, rule: "proc_or_dev"} = Guard.check("/dev/zero", root, :read)
    end

    test "a symlink anywhere in the path is refused, even one that stays inside the root", %{
      root: root
    } do
      File.mkdir_p!(Path.join(root, "real"))
      File.write!(Path.join(root, "real/a.txt"), "a")
      File.ln_s!(Path.join(root, "real"), Path.join(root, "via"))
      assert %{decision: :deny, rule: "symlink"} = Guard.check("via/a.txt", root, :read)
      assert %{decision: :allow} = Guard.check("real/a.txt", root, :read)
    end

    test "the data and secrets directories are refused by path, a new file in them too", %{
      root: root,
      data: data,
      secrets: secrets
    } do
      File.mkdir_p!(data)

      assert %{decision: :deny, rule: "data_dir"} =
               Guard.check(Path.join(data, "x"), root, :write)

      assert %{decision: :deny, rule: "secrets_dir"} =
               Guard.check(Path.join(secrets, "new"), root, :write)

      assert %{decision: :deny, rule: "data_dir"} = Guard.check(data, root, :dir)
    end

    test "a hard link is refused unless the policy opts in", %{root: root, base: base} do
      File.write!(Path.join(base, "elsewhere.txt"), "e")
      :ok = File.ln(Path.join(base, "elsewhere.txt"), Path.join(root, "h.txt"))
      assert %{decision: :deny, rule: "hard_link", nlink: 2} = Guard.check("h.txt", root, :read)

      Application.put_env(:trinity, :fs, roots: [root], allow_hard_links: true)
      assert %{decision: :allow, nlink: 2} = Guard.check("h.txt", root, :read)
    end

    test "an inventoried inode is refused through a hard link even when hard links are allowed",
         %{root: root, secrets: secrets} do
      File.write!(Path.join(secrets, "token"), "t")
      :ok = File.ln(Path.join(secrets, "token"), Path.join(root, "t.txt"))
      Application.put_env(:trinity, :fs, roots: [root], allow_hard_links: true)
      assert %{decision: :deny, rule: "protected_inode"} = Guard.check("t.txt", root, :read)
    end

    test "the deny-list is the second check: it names a file the structural checks passed", %{
      root: root
    } do
      for name <- ~w(a.key b.db b.db-wal b.db-shm c.sqlite3 .env .env.local id_ed25519 cert.pem) do
        File.write!(Path.join(root, name), "x")
        assert %{decision: :deny, rule: "deny_list:" <> _} = Guard.check(name, root, :read), name
      end

      File.write!(Path.join(root, "notes.txt"), "x")
      assert %{decision: :allow} = Guard.check("notes.txt", root, :read)
    end

    test "a special file is refused", %{root: root} do
      {_, 0} = System.cmd("mkfifo", [Path.join(root, "pipe")])
      assert %{decision: :deny, rule: "special_file"} = Guard.check("pipe", root, :read)
    end

    test "a root reached through its symlinked spelling is read as the canonical root", %{
      base: base
    } do
      real = Path.join(base, "realroot")
      File.mkdir_p!(real)
      File.write!(Path.join(real, "a.txt"), "a")
      File.ln_s!(real, Path.join(base, "rootalias"))
      Application.put_env(:trinity, :fs, roots: [Path.join(base, "rootalias")])

      assert %{decision: :allow, canonical: canonical} =
               Guard.check(Path.join(base, "rootalias/a.txt"), nil, :read)

      assert canonical == Path.join(real, "a.txt")
    end
  end

  describe "read/3" do
    test "answers the bytes and the verdict for an allowed file; refuses a denied one", %{
      root: root
    } do
      File.write!(Path.join(root, "a.txt"), "hello")
      assert {:ok, "hello", %{decision: :allow}} = Guard.read("a.txt", root)
      File.write!(Path.join(root, "k.key"), "secret")
      assert {:error, {:fs_denied, %{rule: "deny_list:*.key"}}} = Guard.read("k.key", root)
      assert {:error, {:file, :enoent, _}} = Guard.read("missing.txt", root)
    end

    test "inside a caller's own jail (zones: false) the inode and link checks still hold", %{
      data: data,
      secrets: secrets
    } do
      File.mkdir_p!(Path.join(data, "skills/s"))
      File.write!(Path.join(data, "skills/s/ref.md"), "skill text")

      assert {:ok, "skill text", _} =
               Guard.read(Path.join(data, "skills/s/ref.md"), nil, zones: false)

      File.write!(Path.join(secrets, "k"), "k")
      :ok = File.ln(Path.join(secrets, "k"), Path.join(data, "skills/s/k.md"))

      assert {:error, {:fs_denied, %{rule: rule}}} =
               Guard.read(Path.join(data, "skills/s/k.md"), nil, zones: false)

      assert rule in ["protected_inode", "hard_link"]
    end
  end

  describe "receipt_fields/3" do
    test "carries the AC6 fields and never the file's bytes", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "do-not-copy")
      v = Guard.check("a.txt", root, :read)

      fields =
        Guard.receipt_fields(v, "fs_read", %{
          caller: "s1",
          principal: nil,
          turn_id: "t1"
        })

      assert Map.keys(fields) |> Enum.sort() ==
               Enum.sort(
                 ~w(tool requested_path canonical_path dev ino root deny_rule nlink decision policy_hash principal turn_id)
               )

      assert fields["principal"] == %{"caller" => "s1"}
      assert fields["turn_id"] == "t1"
      refute inspect(fields) =~ "do-not-copy"
    end
  end
end
