# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Registry do
  @moduledoc """
  The skills in force (slice 040): a GenServer that scans the roots (`Trinity.Skills.Sources`),
  keeps every skill it found in an ETS table (reads never wait on the process), writes the
  `skills` index rows (a version bump when a body's digest changes, the owner's `status` kept
  across rescans), and watches the roots that exist for changes (`file_system`: inotify,
  fsevents or the Windows backend where they are, polling every second where `inotifywait`
  is absent), rescanning after a 300 ms quiet period.

  The filesystem scan runs at boot and on every change; the index rows are written on the
  first read after a scan (`list/1` asks for them), not at boot.

  A project's `.trinity/skills` is scanned the first time a caller names the project root
  (`project_root:`) and watched from then on. `list/1` resolves same-named skills by source
  precedence; `active/1` also applies conditional activation: a skill whose
  `requires_tools` are not registered or whose `requires_toolsets` have no registered tool is
  hidden, and one with `fallback_for_toolsets` shows only while those toolsets have no tool.
  """
  use GenServer

  import Ecto.Query

  alias Trinity.Repo
  alias Trinity.Skills.{Row, Skill, Sources}

  require Logger

  @table :trinity_skills
  @debounce_ms 300

  ## Reads (ETS)

  @doc "Every skill found, one per name, the highest-precedence source winning; `project_root:` adds a project's."
  @spec list(keyword()) :: [Skill.t()]
  def list(opts \\ []) do
    ensure_project(opts[:project_root])
    ensure_indexed()

    skills()
    |> Enum.filter(&visible_source?(&1, opts[:project_root]))
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, skills} ->
      [winner | rest] = Enum.sort_by(skills, &Sources.rank(&1.source))
      %{winner | shadows: Enum.map(rest, & &1.source)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "The skills the model may see: `active`, requirements met (see the moduledoc)."
  @spec active(keyword()) :: [Skill.t()]
  def active(opts \\ []) do
    opts |> list() |> Enum.filter(&(&1.status == "active" and requirements_met?(&1)))
  end

  @doc "A skill by name among `list/1`'s."
  @spec get(String.t(), keyword()) :: Skill.t() | nil
  def get(name, opts \\ []), do: opts |> list() |> Enum.find(&(&1.name == name))

  @doc "The errors the last scan met, per root."
  @spec errors() :: [Sources.error()]
  def errors, do: GenServer.call(__MODULE__, :errors)

  @doc "True when the skill's requirements are met by the tools registered now."
  @spec requirements_met?(Skill.t()) :: boolean()
  def requirements_met?(%Skill{} = skill) do
    Enum.all?(Skill.requires_tools(skill), &tool?/1) and
      Enum.all?(Skill.requires_toolsets(skill), &toolset?/1) and
      not Enum.any?(Skill.fallback_for_toolsets(skill), &toolset?/1)
  end

  # The table holds `{{name, source}, %Skill{}}` rows and one `{:indexed, boolean}` marker.
  defp skills, do: for({{_, _}, %Skill{} = s} <- :ets.tab2list(@table), do: s)

  defp ensure_indexed do
    case :ets.lookup(@table, :indexed) do
      [{:indexed, true}] -> :ok
      _ -> GenServer.call(__MODULE__, :ensure_indexed, 30_000)
    end
  end

  ## Writes (the process)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Rescans every root (the projects seen so far included) and rewrites the index; synchronous."
  @spec rescan() :: :ok
  def rescan, do: GenServer.call(__MODULE__, :rescan, 30_000)

  @doc "Sets a skill's status (`active` or `disabled`) by name and source; persisted."
  @spec set_status(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_status(name, source, status) when status in ["active", "disabled"],
    do: GenServer.call(__MODULE__, {:set_status, name, source, status})

  def set_status(_, _, status), do: {:error, {:status, status}}

  @doc "Scans (and from then on watches) a project's skills root; a no-op for a root already known or absent."
  @spec watch_project(String.t() | nil) :: :ok
  def watch_project(nil), do: :ok

  def watch_project(project_dir),
    do: GenServer.call(__MODULE__, {:watch_project, Path.expand(project_dir)})

  @impl true
  def init(_opts) do
    # The watchers are linked; one whose directory went away exits, and that is a watcher
    # to drop, not a registry to restart.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    state = %{projects: MapSet.new(), watchers: %{}, errors: [], timer: nil}
    {:ok, scan_all(state)}
  end

  @impl true
  def handle_call(:rescan, _from, state), do: {:reply, :ok, state |> scan_all() |> index_all()}
  def handle_call(:errors, _from, state), do: {:reply, state.errors, state}

  def handle_call(:ensure_indexed, _from, state) do
    case :ets.lookup(@table, :indexed) do
      [{:indexed, true}] -> {:reply, :ok, state}
      _ -> {:reply, :ok, index_all(state)}
    end
  end

  def handle_call({:set_status, name, source, status}, _from, state) do
    state = if indexed?(), do: state, else: index_all(state)

    case Repo.get_by(Row, name: name, source: source) do
      nil ->
        {:reply, {:error, :not_found}, state}

      row ->
        {:ok, _} = row |> Row.changeset(%{status: status}) |> Repo.update()

        case :ets.lookup(@table, {name, source}) do
          [{key, skill}] -> :ets.insert(@table, {key, %{skill | status: status}})
          [] -> :ok
        end

        {:reply, :ok, state}
    end
  end

  def handle_call({:watch_project, dir}, _from, state) do
    if MapSet.member?(state.projects, dir) do
      {:reply, :ok, state}
    else
      state = %{state | projects: MapSet.put(state.projects, dir)}
      {:reply, :ok, scan_all(state)}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {_path, _events}}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :rescan_after_quiet, @debounce_ms)}}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, state) do
    watchers = state.watchers |> Enum.reject(fn {_dir, p} -> p == pid end) |> Map.new()
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_info(:rescan_after_quiet, state), do: {:noreply, scan_all(%{state | timer: nil})}
  def handle_info(_other, state), do: {:noreply, state}

  ## The scan

  # The filesystem into ETS. A skill keeps the status and version the table held for it; the
  # rows are written on the next read (`index_all/1`), not here: nothing at boot needs them,
  # and under the test sandbox a connection taken at boot belongs to whoever took it first.
  defp scan_all(state) do
    roots = Sources.roots() ++ Enum.map(state.projects, &Sources.project_root/1)

    {found, errors} =
      Enum.reduce(roots, {[], []}, fn root, {s, e} ->
        {s2, e2} = Sources.scan(root)
        {s ++ s2, e ++ e2}
      end)

    previous = Map.new(skills(), &{{&1.name, &1.source}, &1})

    found =
      Enum.map(found, fn skill ->
        case Map.get(previous, {skill.name, skill.source}) do
          %Skill{status: status, version: v} -> %{skill | status: status, version: v}
          nil -> skill
        end
      end)

    :ets.delete_all_objects(@table)
    for skill <- found, do: :ets.insert(@table, {{skill.name, skill.source}, skill})
    :ets.insert(@table, {:indexed, false})

    for e <- errors,
        do: Logger.warning("skills: #{e.dir} (#{e.source}) not loaded: #{inspect(e.reason)}")

    %{state | errors: errors, watchers: watch(roots, state.watchers)}
  end

  # The rows for what the table holds: written or updated, statuses and versions read back,
  # the rows of skills gone from every root removed.
  defp index_all(state) do
    indexed = Enum.map(skills(), &index/1)
    for skill <- indexed, do: :ets.insert(@table, {{skill.name, skill.source}, skill})
    prune(indexed)
    :ets.insert(@table, {:indexed, true})
    state
  end

  defp indexed?, do: match?([{:indexed, true}], :ets.lookup(@table, :indexed))

  # The row for a skill: created, or updated with a version bump when the body changed; the
  # row's status is the skill's.
  defp index(%Skill{} = skill) do
    attrs = %{
      name: skill.name,
      source: skill.source,
      scope: skill.scope,
      path: skill.path,
      frontmatter: frontmatter(skill),
      body_hash: skill.body_hash,
      scan_result: %{
        "manifest" => skill.manifest,
        "references" => skill.references,
        "scripts" => skill.scripts
      }
    }

    row =
      case Repo.get_by(Row, name: skill.name, source: skill.source) do
        nil ->
          Repo.insert!(Row.changeset(%Row{}, Map.put(attrs, :status, "active")))

        %Row{} = row ->
          version = if row.body_hash == skill.body_hash, do: row.version, else: row.version + 1
          Repo.update!(Row.changeset(row, Map.put(attrs, :version, version)))
      end

    %{skill | status: row.status, version: row.version}
  end

  defp frontmatter(%Skill{} = s) do
    %{
      "description" => s.description,
      "category" => s.category,
      "license" => s.license,
      "compatibility" => s.compatibility,
      "metadata" => s.metadata,
      "allowed-tools" => s.allowed_tools,
      "trinity" => s.trinity
    }
  end

  # Rows whose skill is gone from every root this scan saw.
  defp prune(skills) do
    keep = Enum.map(skills, &{&1.name, &1.source})

    Repo.all(from(r in Row, select: {r.id, r.name, r.source}))
    |> Enum.reject(fn {_, n, s} -> {n, s} in keep end)
    |> Enum.each(fn {id, _, _} -> Repo.delete_all(from(r in Row, where: r.id == ^id)) end)
  end

  ## Watching

  # Watchers for the roots that exist; a watcher on a directory that is gone is stopped.
  defp watch(roots, watchers) do
    if watch?() do
      {gone, kept} = Enum.split_with(watchers, fn {dir, _} -> not File.dir?(dir) end)
      for {_, pid} when is_pid(pid) <- gone, do: Process.exit(pid, :shutdown)
      Enum.reduce(roots, Map.new(kept), &watch_root/2)
    else
      watchers
    end
  end

  defp watch_root(%{dir: dir}, acc) do
    if Map.has_key?(acc, dir) or not File.dir?(dir),
      do: acc,
      else: Map.put(acc, dir, start_watcher(dir))
  end

  defp start_watcher(dir) do
    opts = [dirs: [dir]] ++ backend()

    case FileSystem.start_link(opts) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      other ->
        Logger.warning(
          "skills: no watcher on #{dir} (#{inspect(other)}); the reindex button and mix trinity.skills.reindex still work"
        )

        nil
    end
  end

  # inotify needs the `inotifywait` executable; without it, and on any platform file_system
  # has no native backend for, poll once a second (AC3's 2 s still holds).
  defp backend do
    case :os.type() do
      {:unix, :linux} ->
        if System.find_executable("inotifywait"),
          do: [],
          else: [backend: :fs_poll, interval: 1_000]

      {:unix, :darwin} ->
        []

      {:win32, _} ->
        []

      _ ->
        [backend: :fs_poll, interval: 1_000]
    end
  end

  defp watch?, do: Application.get_env(:trinity, :skills, []) |> Keyword.get(:watch, true)

  ## Helpers

  defp ensure_project(nil), do: :ok
  defp ensure_project(dir), do: watch_project(dir)

  # A project's skills are shown only to a caller that named that project.
  defp visible_source?(%Skill{source: "project", path: path}, project_root)
       when is_binary(project_root),
       do:
         String.starts_with?(path, Path.join(Path.expand(project_root), ".trinity/skills") <> "/")

  defp visible_source?(%Skill{source: "project"}, _), do: false
  defp visible_source?(_, _), do: true

  defp tool?(name), do: match?({:ok, _}, Trinity.Tools.lookup(name))

  defp toolset?(name) do
    set = String.to_existing_atom(name)
    Trinity.Tools.list(toolset: set) != []
  rescue
    ArgumentError -> false
  end
end
