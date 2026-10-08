# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.SecretsCensusTest do
  @moduledoc """
  Slice 135, AC3: a census. It walks the data directory and the secrets directory and asserts that
  no file in either is reachable through any configured root by any tool in the registry that takes
  a path.

  **Both populations come from the tree.** The files are what a walk of the two directories finds
  (a release's layout is planted first: keys, the registry, the MCP state key and bearer token, an
  OAuth token, the databases and their journals, settings, a backup). The tools are the registry's
  entries whose schema takes `path`, `file` or `cwd`, and the census fails if that set is not the set
  it knows how to call, so a path-taking tool added later is a failure here until it is.

  **Routes.** For a tool that takes a file: the direct path, `..` from a root, a symlink inside a
  root, a hard link inside a root, and `/proc/self/fd/N`. For a tool that takes a directory: the
  file's directory directly, through `..` and through a symlink, and the root itself holding a
  symlink and a hard link to the file. `skill_file` is jailed to a skill's directory, so its routes
  are a symlink and a hard link planted inside a project skill. Each call goes through
  `Trinity.Effects.Runner.run/2`; an approval request is answered "allow once" and the call made
  again, because an ask the owner approves is not a refusal.

  **What counts as reached.** The file's bytes in the tool's answer, or the file changed (bytes or
  inode) by the call, or (for `learn`) the bytes in a staged skill change.

  **What the census does not cover, stated.** `shell`'s path argument is its working directory, and
  that is held here; the command text is free text and can name any file, and no path check can
  read it. The shell is `:exec`, asks every time, and docs/07 states the BEAM is not an OS sandbox.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Effects
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools.Context

  @env ["XDG_DATA_HOME", "TRINITY_SECRETS_DIR"]
  @moduletag timeout: 300_000

  # The path-taking tools this census knows how to call, by how they take a path.
  @file_tools ~w(fs_read fs_write fs_edit learn)
  @dir_tools ~w(fs_list fs_glob fs_grep shell)
  @jailed_tools ~w(skill_file)
  # Takes a path relative to a staged skill tree and refuses an absolute one or `..` itself; called
  # with the file routes all the same.
  @relative_tools ~w(skill_manage)

  setup do
    base = Path.join(System.tmp_dir!(), "s135c-#{System.unique_integer([:positive])}")
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
    {:ok, _} = Trinity.Sessions.set_project_root(session.id, root)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Application.put_env(:trinity, :fs, saved_fs)
      Receipts.stop_writer(Receipts.session_scope(session.id))
      File.rm_rf!(base)
    end)

    plant_release_layout!(Trinity.Paths.data_dir(), secrets)
    ctx = %Context{session_id: session.id, caller: session.id, cwd: root}
    {:ok, root: root, secrets: secrets, ctx: ctx}
  end

  # What a release keeps, where this tree keeps it: the keys wherever `Trinity.Paths.keys_dir/0`
  # puts them, and every other secret under the secrets directory, the databases and settings in
  # the data directory.
  defp plant_release_layout!(data, secrets) do
    keys = Trinity.Paths.keys_dir()

    files = [
      Path.join(keys, "receipts-ed25519.key"),
      Path.join(keys, "registry.json"),
      Path.join(keys, "mcp-state.key"),
      Path.join(secrets, "mcp-server-token"),
      Path.join([secrets, "oauth", "resource.json"]),
      Path.join(data, "trinity.db"),
      Path.join(data, "trinity.db-wal"),
      Path.join(data, "receipts.db"),
      Path.join(data, "settings.json"),
      Path.join([data, "backups", "abc", "20261008T000000Z-1"])
    ]

    for f <- files do
      File.mkdir_p!(Path.dirname(f))
      File.write!(f, "SENTINEL-#{System.unique_integer([:positive])}-END\n")
    end
  end

  # The population: every regular file under the data directory and the secrets directory.
  defp walk(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&match?({:ok, %{type: :regular}}, File.lstat(&1)))
  end

  defp run(ctx, name, args, n \\ 0) do
    call = %{id: "k#{n}-#{System.unique_integer([:positive])}", name: name, args: args}

    case Effects.Runner.run(call, ctx) do
      {:error, {:approval_required, id}, _} when n < 2 ->
        {:ok, _} = Permissions.decide_request(id, :once)
        run(ctx, name, args, n + 1)

      other ->
        other
    end
  end

  defp dotdot(root, target) do
    ups = root |> Path.split() |> tl() |> Enum.map_join("/", fn _ -> ".." end)
    ups <> target
  end

  defp open_fd(path) do
    {:ok, io} = File.open(path, [:read])
    on_exit(fn -> File.close(io) end)

    fd =
      "/proc/self/fd"
      |> File.ls!()
      |> Enum.find(fn n -> match?({:ok, ^path}, File.read_link("/proc/self/fd/" <> n)) end)

    fd && "/proc/self/fd/" <> fd
  end

  defp file_routes(root, file, i) do
    sym = Path.join(root, "census-sym-#{i}.txt")
    hard = Path.join(root, "census-hard-#{i}.txt")
    File.ln_s!(file, sym)
    :ok = File.ln(file, hard)

    [direct: file, dotdot: dotdot(root, file), symlink: sym, hardlink: hard, proc: open_fd(file)]
    |> Enum.reject(fn {_, p} -> is_nil(p) end)
  end

  # `shell` is called with its working directory as the path and `cat ./*` as the command. The root
  # holding links is left out for it alone: there the command, not the path, names the file, which
  # is the residual the moduledoc states.
  defp dir_routes(tool, root, file, i) do
    dir = Path.dirname(file)
    sym = Path.join(root, "census-dir-#{i}")
    File.ln_s!(dir, sym)
    routes = [direct: dir, dotdot: dotdot(root, dir), symlink: sym]
    if tool == "shell", do: routes, else: routes ++ [root_with_links: root]
  end

  defp args("fs_read", p, _), do: %{"path" => p}
  defp args("fs_write", p, _), do: %{"path" => p, "content" => "overwritten\n"}
  defp args("fs_edit", p, bytes), do: %{"path" => p, "search" => bytes, "replace" => "edited"}
  defp args("learn", p, _), do: %{"file" => p}

  defp args("skill_manage", p, _),
    do: %{
      "action" => "write_file",
      "name" => "census",
      "rationale" => "census",
      "path" => p,
      "content" => "x"
    }

  defp args("fs_list", p, _), do: %{"path" => p}
  defp args("fs_glob", p, _), do: %{"pattern" => "**/*", "path" => p}
  defp args("fs_grep", p, _), do: %{"pattern" => "SENTINEL", "path" => p}
  defp args("shell", p, _), do: %{"command" => "cat ./* 2>/dev/null; true", "cwd" => p}

  defp reached?(outcome, file, bytes, stat) do
    content =
      case outcome do
        {:ok, %{content: c}, _} -> c
        _ -> ""
      end

    after_stat = File.lstat(file)

    cond do
      String.contains?(content, String.trim(bytes)) -> :content
      File.read(file) != {:ok, bytes} -> :changed
      inode(after_stat) != inode(stat) -> :replaced
      true -> nil
    end
  end

  defp restore!(file, bytes) do
    File.rm(file)
    File.write!(file, bytes)
  end

  defp inode({:ok, %{inode: i, major_device: d}}), do: {d, i}
  defp inode(_), do: nil

  # A project skill under the root, for `skill_file`'s jail.
  defp skill_dir!(root) do
    dir = Path.join([root, ".trinity", "skills", "census"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: census
    description: A skill the census plants links in. Use never.
    ---

    # Census
    """)

    dir
  end

  test "the path-taking tools in the registry are the ones this census calls" do
    # The suite's own fixtures (`Trinity.TestTools.*`, test/support/tools) are not in the tree that
    # ships: `write_note` pretends to write and touches nothing.
    taking =
      for %{name: name, module: module} = entry <- Trinity.Tools.list(),
          not String.starts_with?(inspect(module), "Trinity.TestTools."),
          props = get_in(Trinity.Tools.Registry.schema(entry), ["properties"]) || %{},
          Enum.any?(~w(path file cwd), &Map.has_key?(props, &1)),
          do: name

    assert Enum.sort(taking) ==
             Enum.sort(@file_tools ++ @dir_tools ++ @jailed_tools ++ @relative_tools)
  end

  test "no file under the data directory or the secrets directory is reachable", %{
    root: root,
    secrets: secrets,
    ctx: ctx
  } do
    population = walk(Trinity.Paths.data_dir()) ++ walk(secrets)
    assert length(population) >= 10, "the planted layout is the floor: #{inspect(population)}"
    skill = skill_dir!(root)

    breaches =
      population
      |> Enum.with_index()
      |> Enum.flat_map(fn {file, i} ->
        bytes = File.read!(file)

        # Each call is judged on its own: the file is put back after one that changed it, so a
        # write that got through is one breach and not every later route's.
        check = fn tool, route, p, args ->
          stat = File.lstat(file)
          outcome = run(ctx, tool, args)
          how = reached?(outcome, file, bytes, stat)
          if how in [:changed, :replaced], do: restore!(file, bytes)
          how && %{file: file, tool: tool, route: route, path: p, how: how}
        end

        file_calls =
          for tool <- @file_tools ++ @relative_tools,
              {route, p} <- file_routes(root, file, "#{i}-#{tool}"),
              do: check.(tool, route, p, args(tool, p, String.trim(bytes)))

        dir_calls =
          for tool <- @dir_tools,
              {route, p} <- dir_routes(tool, root, file, "#{i}-#{tool}"),
              do: check.(tool, route, p, args(tool, p, bytes))

        File.ln_s!(file, Path.join(skill, "sym-#{i}.md"))
        :ok = File.ln(file, Path.join(skill, "hard-#{i}.md"))

        skill_calls =
          for {route, rel} <- [symlink: "sym-#{i}.md", hardlink: "hard-#{i}.md"],
              do: check.("skill_file", route, rel, %{"name" => "census", "path" => rel})

        Enum.reject(file_calls ++ dir_calls ++ skill_calls, &is_nil/1)
      end)

    pending = Application.get_env(:trinity, :skills, [])[:pending_dir]

    staged =
      for f <- walk(pending),
          s <- population,
          String.contains?(File.read!(f), "SENTINEL"),
          do: {f, s}

    assert breaches == [],
           "#{length(breaches)} routes reached a protected file:\n" <>
             Enum.map_join(Enum.take(breaches, 40), "\n", &inspect/1)

    assert staged == []
  end
end
