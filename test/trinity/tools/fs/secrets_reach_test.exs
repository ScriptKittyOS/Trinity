# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.SecretsReachTest do
  @moduledoc """
  Slice 135, AC1, AC3 and AC6: a tool the agent calls cannot read or write a secret or a database
  file of Trinity's own, by any path.

  **The production layout, not the suite's.** `config/test.exs` points the receipt keys at
  `tmp/test_keys`, outside the data directory, which hid the defect from every earlier test. Here
  the data directory is moved to a temporary directory through `XDG_DATA_HOME` (which
  `Trinity.Paths.data_dir/0` reads on Linux at each call) and the secrets directory through
  `TRINITY_SECRETS_DIR`, and the key is planted where `Trinity.Paths.keys_dir/0` puts it in a
  release. Every call goes through `Trinity.Effects.Runner.run/2`, the runner the Session uses,
  with the default policy (`Policy.Layered`, `read: :allow`).

  **An ask is not a refusal.** A read that asks and is then approved returns the bytes, and an owner
  approving `/proc/self/fd/7` cannot know it is the key. So every route here answers an approval
  request with "allow once" and runs the call again, as the owner clicking the card would; the
  assertion is on what comes back after that.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Effects
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools.Context

  @env ["XDG_DATA_HOME", "TRINITY_SECRETS_DIR"]

  setup do
    base = Path.join(System.tmp_dir!(), "s135-#{System.unique_integer([:positive])}")
    xdg = Path.join(base, "xdg")
    secrets = Path.join(base, "secrets")
    root = Path.join(base, "root")
    Enum.each([xdg, secrets, root], &File.mkdir_p!/1)

    saved_env = Map.new(@env, &{&1, System.get_env(&1)})
    saved_fs = Application.get_env(:trinity, :fs, [])
    System.put_env("XDG_DATA_HOME", xdg)
    System.put_env("TRINITY_SECRETS_DIR", secrets)
    Application.put_env(:trinity, :fs, Keyword.put(saved_fs, :roots, [root]))

    session = Trinity.Factory.session!()
    scope = Receipts.session_scope(session.id)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Application.put_env(:trinity, :fs, saved_fs)
      Receipts.stop_writer(scope)
      File.rm_rf!(base)
    end)

    # Where a release keeps the receipt key: `Trinity.Paths.keys_dir/0` in force on this tree.
    key = Path.join(Trinity.Paths.keys_dir(), "receipts-ed25519.key")
    secret = "PRIVATE-#{System.unique_integer([:positive])}-SENTINEL"
    File.write!(key, ~s({"private_b64":"#{secret}"}))

    ctx = %Context{session_id: session.id, caller: session.id, cwd: root}
    {:ok, base: base, root: root, key: key, secret: secret, ctx: ctx, scope: scope}
  end

  # One call through the runner in force; an approval request is answered "allow once" and the
  # call is made again, as the owner would.
  defp run(ctx, name, args, n \\ 0) do
    call = %{id: "c#{n}-#{System.unique_integer([:positive])}", name: name, args: args}

    case Effects.Runner.run(call, ctx) do
      {:error, {:approval_required, id}, _} when n < 2 ->
        {:ok, _} = Permissions.decide_request(id, :once)
        run(ctx, name, args, n + 1)

      other ->
        other
    end
  end

  defp leaked?({:ok, %{content: content}, _}, secret), do: String.contains?(content, secret)
  defp leaked?(_, _), do: false

  # The relative path from `root` to `target` that climbs to `/` through `..` and back down.
  defp dotdot(root, target) do
    ups = root |> Path.split() |> tl() |> Enum.map_join("/", fn _ -> ".." end)
    ups <> target
  end

  # The descriptor number this VM holds open on `path`, read from /proc/self/fd.
  defp open_fd!(path) do
    {:ok, io} = File.open(path, [:read])
    on_exit(fn -> File.close(io) end)

    "/proc/self/fd"
    |> File.ls!()
    |> Enum.find(fn n -> match?({:ok, ^path}, File.read_link("/proc/self/fd/" <> n)) end)
  end

  describe "AC1: fs_read of the receipt key" do
    test "by direct path", %{key: key, secret: secret, ctx: ctx} do
      outcome = run(ctx, "fs_read", %{"path" => key})
      refute leaked?(outcome, secret), "the key came back: #{inspect(outcome)}"
      assert {:error, {:fs_denied, _}, _} = outcome
    end

    test "via .. from a root", %{root: root, key: key, secret: secret, ctx: ctx} do
      outcome = run(ctx, "fs_read", %{"path" => dotdot(root, key)})
      refute leaked?(outcome, secret), "the key came back: #{inspect(outcome)}"
      assert {:error, {:fs_denied, _}, _} = outcome
    end

    test "via a symlink inside a root", %{root: root, key: key, secret: secret, ctx: ctx} do
      File.ln_s!(key, Path.join(root, "notes.txt"))
      outcome = run(ctx, "fs_read", %{"path" => "notes.txt"})
      refute leaked?(outcome, secret), "the key came back: #{inspect(outcome)}"
      assert {:error, {:fs_denied, _}, _} = outcome
    end

    test "via a hard link inside a root on the same filesystem", %{
      root: root,
      key: key,
      secret: secret,
      ctx: ctx
    } do
      :ok = File.ln(key, Path.join(root, "notes.txt"))
      outcome = run(ctx, "fs_read", %{"path" => "notes.txt"})
      refute leaked?(outcome, secret), "the key came back: #{inspect(outcome)}"
      assert {:error, {:fs_denied, _}, _} = outcome
    end

    test "via /proc/self/fd/N", %{key: key, secret: secret, ctx: ctx} do
      fd = open_fd!(key)
      assert fd, "no descriptor of this VM points at the key"
      outcome = run(ctx, "fs_read", %{"path" => "/proc/self/fd/" <> fd})
      refute leaked?(outcome, secret), "the key came back: #{inspect(outcome)}"
      assert {:error, {:fs_denied, _}, _} = outcome
    end

    test "fs_grep over a root holding a hard link to the key", %{
      root: root,
      key: key,
      secret: secret,
      ctx: ctx
    } do
      :ok = File.ln(key, Path.join(root, "notes.txt"))
      File.write!(Path.join(root, "plain.txt"), "PRIVATE plain line\n")
      outcome = run(ctx, "fs_grep", %{"pattern" => "PRIVATE"})
      refute leaked?(outcome, secret), "the key came back: #{inspect(outcome)}"
      assert {:ok, %{content: content}, _} = outcome
      assert content =~ "plain.txt"
    end
  end

  describe "AC6: every fs decision is receipted" do
    test "an allowed read and a denied one each carry the fields", %{
      root: root,
      key: key,
      ctx: ctx,
      scope: scope
    } do
      File.write!(Path.join(root, "a.txt"), "hello\n")
      assert {:ok, _, _} = run(ctx, "fs_read", %{"path" => "a.txt"})
      _ = run(ctx, "fs_read", %{"path" => key})

      fs =
        scope
        |> Receipts.list(kind: "decision")
        |> Enum.flat_map(&(JSON.decode!(&1.signed_payload)["decision"]["fs"] || []))

      allowed = Enum.find(fs, &(&1["decision"] == "allow"))
      denied = Enum.find(fs, &(&1["decision"] == "deny"))
      assert allowed, "no allowed fs decision in #{inspect(fs)}"
      assert denied, "no denied fs decision in #{inspect(fs)}"

      for entry <- [allowed, denied] do
        for field <-
              ~w(tool requested_path canonical_path dev ino root deny_rule nlink decision policy_hash principal turn_id),
            do: assert(Map.has_key?(entry, field), "#{field} missing from #{inspect(entry)}")
      end

      assert allowed["tool"] == "fs_read"
      assert allowed["requested_path"] == "a.txt"
      assert allowed["canonical_path"] == Path.join(root, "a.txt")
      assert allowed["root"] == root
      assert is_integer(allowed["ino"]) and allowed["nlink"] == 1
      assert denied["requested_path"] == key
      assert denied["root"] == nil
      assert is_binary(denied["deny_rule"])
      assert denied["policy_hash"] == Trinity.CorePolicy.hash()
    end

    test "a refusal at open, inside a directory a grep walked, rides on the query receipt", %{
      root: root,
      key: key,
      ctx: ctx,
      scope: scope
    } do
      :ok = File.ln(key, Path.join(root, "notes.txt"))
      assert {:ok, _, _} = run(ctx, "fs_grep", %{"pattern" => "PRIVATE"})

      [query] = Receipts.list(scope, kind: "query")
      fs = JSON.decode!(query.signed_payload)["decision"]["fs"]
      # The key is inventoried, so the inode check names it before the link count would.
      assert [%{"deny_rule" => "protected_inode", "nlink" => 2, "decision" => "deny"} = entry] =
               fs

      assert entry["canonical_path"] == Path.join(root, "notes.txt")
      assert entry["tool"] == "fs_grep"
    end
  end
end
