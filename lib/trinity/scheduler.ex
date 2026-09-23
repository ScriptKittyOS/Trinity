# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler do
  @moduledoc """
  Scheduled agent tasks (slice 050): a `tasks` row is a prompt on a schedule, a `task_runs` row one
  execution of it, and Oban carries the work. The schedule is the tree's, not Oban's cron plugin's
  (whose table is static): every task carries the time it next runs, computed here from its cron
  expression or its one-shot datetime, and one plugin entry a minute (`Trinity.Scheduler.Workers.Tick`)
  enqueues a `RunTask` job for each task that is due, unique on the task and the scheduled time,
  then advances the task. `run_now/1` enqueues one at once.

  What this context offers: the rows (`list_tasks/0`, `get_task/1`, `create_task/1`, `update_task/2`,
  `delete_task/1`), the schedule (`next_run_at/2`), the runs (`runs/2`, `recent_runs/1`,
  `unseen_runs/0`, `mark_seen/1`) and the enqueueing (`enqueue_due/1`, `run_now/1`). The topic
  `tasks` carries `{:task_run, %Run{}}` when a run is delivered.
  """
  use Boundary,
    # Slice 070: a run can be delivered to a channel, which is the one thing the scheduler asks
    # of the gateway layer (docs/01's row said so when 050 was built).
    deps: [Trinity, Trinity.Sessions, Trinity.LLM, Trinity.Gateways],
    exports: [
      Task,
      Run,
      Delivery,
      Delivery.Desktop,
      Delivery.Gateway,
      Parse,
      Workers.Tick,
      Workers.RunTask
    ]

  import Ecto.Query, only: [from: 2]

  alias Trinity.Repo
  alias Trinity.Scheduler.{Run, Task}
  alias Trinity.Scheduler.Workers.RunTask

  @topic "tasks"

  ## Tasks

  @doc "Every task, by name."
  @spec list_tasks() :: [Task.t()]
  def list_tasks, do: Repo.all(from(t in Task, order_by: t.name))

  @doc "A task by id."
  @spec get_task(String.t()) :: Task.t() | nil
  def get_task(id), do: Repo.get(Task, id)

  @doc "Creates a task; `next_run_at` is computed from the schedule."
  @spec create_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> put_next_run()
    |> Repo.insert()
  end

  @doc "Updates a task; a changed schedule recomputes `next_run_at`."
  @spec update_task(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> put_next_run()
    |> Repo.update()
  end

  @doc "Removes a task and its runs."
  @spec delete_task(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete_task(%Task{} = task), do: Repo.delete(task)

  @doc "A changeset for a form."
  @spec change_task(Task.t(), map()) :: Ecto.Changeset.t()
  def change_task(%Task{} = task, attrs \\ %{}), do: Task.changeset(task, attrs)

  defp put_next_run(changeset) do
    if changeset.valid? and
         (Ecto.Changeset.changed?(changeset, :schedule) or
            Ecto.Changeset.changed?(changeset, :kind) or
            Ecto.Changeset.get_field(changeset, :next_run_at) == nil) do
      kind = Ecto.Changeset.get_field(changeset, :kind)
      schedule = Ecto.Changeset.get_field(changeset, :schedule)
      Ecto.Changeset.put_change(changeset, :next_run_at, next_run_at(kind, schedule))
    else
      changeset
    end
  end

  @doc """
  When a schedule next fires after `from` (now by default): the next matching minute of a cron
  expression, or the one-shot datetime itself (nil once it is past).
  """
  @spec next_run_at(String.t(), String.t(), DateTime.t()) :: DateTime.t() | nil
  def next_run_at(kind, schedule, from \\ DateTime.utc_now())

  def next_run_at("cron", schedule, from) do
    case Task.parse("cron", schedule) do
      {:ok, expr} ->
        case Oban.Cron.Expression.next_at(expr, from) do
          %DateTime{} = at -> usec(at)
          :unknown -> nil
        end

      {:error, _} ->
        nil
    end
  end

  def next_run_at("once", schedule, from) do
    case Task.parse("once", schedule) do
      {:ok, at} -> if DateTime.compare(at, from) == :gt, do: usec(at), else: nil
      {:error, _} -> nil
    end
  end

  # The columns carry microseconds; Oban's parser answers whole minutes and an ISO string
  # whatever it carried.
  defp usec(%DateTime{} = at), do: DateTime.add(at, 0, :microsecond)

  ## Enqueueing

  @doc """
  Enqueues a run for every enabled task whose `next_run_at` is at or before `now`, unique on the
  task and that time (a tick that fires twice enqueues once), and advances each task: a cron task
  to its next minute after `now`, a one-shot task to nothing (disabled). Returns the runs enqueued.
  """
  @spec enqueue_due(DateTime.t()) :: [Run.t()]
  def enqueue_due(now \\ DateTime.utc_now()) do
    due =
      Repo.all(
        from(t in Task, where: t.enabled and not is_nil(t.next_run_at) and t.next_run_at <= ^now)
      )

    for task <- due, {:ok, run} <- [enqueue(task, task.next_run_at)] do
      advance(task, now)
      run
    end
  end

  @doc "Enqueues one run of a task now (the page's button); the scheduled time is now."
  @spec run_now(Task.t()) :: {:ok, Run.t()} | {:error, term()}
  def run_now(%Task{} = task), do: enqueue(task, usec(DateTime.utc_now()))

  # The run row first (unique on task and time: a second enqueue for the same time is refused
  # here, and the job's own uniqueness is the second lock), then the job carrying its id.
  defp enqueue(%Task{} = task, %DateTime{} = at) do
    at = usec(at)

    with {:ok, run} <- Repo.insert(Run.changeset(%Run{}, %{task_id: task.id, scheduled_at: at})),
         {:ok, _job} <-
           %{"run_id" => run.id, "task_id" => task.id, "scheduled_at" => DateTime.to_iso8601(at)}
           |> RunTask.new()
           |> Oban.insert() do
      {:ok, run}
    else
      {:error, %Ecto.Changeset{errors: [task_id: {_, [constraint: :unique, constraint_name: _]}]}} ->
        {:error, :already_scheduled}

      {:error, %Ecto.Changeset{} = cs} ->
        if Keyword.has_key?(cs.errors, :task_id) or Keyword.has_key?(cs.errors, :scheduled_at),
          do: {:error, :already_scheduled},
          else: {:error, cs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance(%Task{kind: "cron"} = task, now),
    do:
      Repo.update!(
        Ecto.Changeset.change(task, next_run_at: next_run_at("cron", task.schedule, now))
      )

  defp advance(%Task{kind: "once"} = task, _now),
    do: Repo.update!(Ecto.Changeset.change(task, next_run_at: nil, enabled: false))

  ## Runs

  @doc "A task's runs, newest first (`limit:`)."
  @spec runs(Task.t() | String.t(), keyword()) :: [Run.t()]
  def runs(task_or_id, opts \\ []) do
    id = if is_binary(task_or_id), do: task_or_id, else: task_or_id.id
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from(r in Run, where: r.task_id == ^id, order_by: [desc: r.scheduled_at], limit: ^limit)
    )
  end

  @doc "A run by id."
  @spec get_run(String.t()) :: Run.t() | nil
  def get_run(id), do: Repo.get(Run, id)

  @doc "The latest runs across every task, newest first, with their tasks."
  @spec recent_runs(keyword()) :: [Run.t()]
  def recent_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    Repo.all(from(r in Run, order_by: [desc: r.scheduled_at], limit: ^limit, preload: :task))
  end

  @doc "The finished runs the owner has not seen, oldest first (the notifications list)."
  @spec unseen_runs() :: [Run.t()]
  def unseen_runs do
    Repo.all(
      from(r in Run,
        where: r.status in ["ok", "failed"] and is_nil(r.seen_at),
        order_by: r.finished_at,
        preload: :task
      )
    )
  end

  @doc "Marks a run seen."
  @spec mark_seen(Run.t() | String.t()) :: {:ok, Run.t()} | {:error, term()}
  def mark_seen(%Run{} = run),
    do: run |> Run.changeset(%{seen_at: DateTime.utc_now()}) |> Repo.update()

  def mark_seen(id) when is_binary(id) do
    case get_run(id) do
      nil -> {:error, :not_found}
      run -> mark_seen(run)
    end
  end

  @doc "Updates a run (the workers' path)."
  @spec update_run(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%Run{} = run, attrs), do: run |> Run.changeset(attrs) |> Repo.update()

  ## Topic

  @doc "The PubSub topic a delivered run is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to `{:task_run, %Run{}}`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Trinity.PubSub, @topic)

  @doc "Broadcasts a delivered run."
  @spec broadcast(Run.t()) :: :ok
  def broadcast(%Run{} = run),
    do: Phoenix.PubSub.broadcast(Trinity.PubSub, @topic, {:task_run, run})
end
