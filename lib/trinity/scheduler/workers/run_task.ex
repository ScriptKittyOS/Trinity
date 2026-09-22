# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Workers.RunTask do
  @moduledoc """
  One run of a task (slice 050): a fresh session with `origin: "cron"` titled after the task and
  the persona the task names, one turn with the task's prompt (and a line naming the skills it
  hints), the wait for the turn to end on the session's topic (the task's `timeout_ms`), the
  assistant's answer as the run's summary, the delivery. A turn that ends in the session's error
  state, times out or raises is `{:error, reason}`: Oban retries under `max_attempts` (3) with its
  backoff, and the run is `retrying` until the last attempt marks it `failed` with the error.

  A tool call that asks for approval in a cron session has nobody at the desk: the request waits
  its expiry on the permissions page (021, ten minutes by default) and the turn goes on with the
  denial, which the summary shows. That is the honest outcome, recorded in docs/07.
  """
  use Oban.Worker,
    queue: :agent_tasks,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:run_id]]

  require Logger

  alias Trinity.Scheduler
  alias Trinity.Scheduler.{Delivery, Run, Task}
  alias Trinity.Sessions

  @summary_bytes 2_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}, attempt: attempt, max_attempts: max}) do
    with %Run{} = run <- Scheduler.get_run(run_id) || {:error, :run_missing},
         %Task{} = task <- Scheduler.get_task(run.task_id) || {:error, :task_missing} do
      {:ok, run} =
        Scheduler.update_run(run, %{
          status: "running",
          attempt: attempt,
          started_at: DateTime.utc_now()
        })

      case execute(run, task) do
        {:ok, session_id, summary} ->
          finish(run, task, session_id, summary)

        {:error, reason} ->
          fail(run, reason, attempt, max)
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  @impl Oban.Worker
  def timeout(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Scheduler.get_run(run_id) do
      %Run{task_id: task_id} ->
        case Scheduler.get_task(task_id) do
          %Task{timeout_ms: ms} -> ms + 5_000
          nil -> :infinity
        end

      nil ->
        :infinity
    end
  end

  # The session's process broadcasts `:idle` once when it starts; that one is drained before
  # the message goes, so the wait below is for the turn's own.
  defp execute(run, task) do
    with {:ok, session} <- session(run, task),
         :ok <- Sessions.subscribe(session.id),
         {:ok, _pid} <- Sessions.ensure_started(session.id),
         :ok <- drain_start(session.id),
         {:ok, _message} <- Sessions.send_user_message(session.id, prompt(task)),
         :ok <- await_idle(session.id, task.timeout_ms) do
      {:ok, session.id, summary(session.id)}
    end
  end

  defp drain_start(session_id) do
    receive do
      {:session, ^session_id, {:state, :idle}} -> :ok
    after
      2_000 -> :ok
    end
  end

  # One session per run, so the history a run leaves is its own; the row records the task and
  # the run in `origin_ref`.
  defp session(run, task) do
    Sessions.create_session(%{
      persona_id: task.persona_id || Sessions.default_persona().id,
      origin: "cron",
      title: task.name,
      origin_ref: %{"task_id" => task.id, "run_id" => run.id}
    })
  end

  defp prompt(%Task{prompt: prompt, skill_names: []}), do: prompt

  defp prompt(%Task{prompt: prompt, skill_names: names}),
    do: prompt <> "\n\n(Use the skills " <> Enum.join(names, ", ") <> " where they apply.)"

  # The turn ends at :idle; the session's :error state is a failure; the timeout is the task's.
  defp await_idle(session_id, timeout_ms) do
    receive do
      {:session, ^session_id, {:state, :idle}} -> :ok
      {:session, ^session_id, {:state, :error}} -> {:error, :session_error}
      {:session, ^session_id, {:error, reason}} -> {:error, {:turn, reason}}
      {:session, ^session_id, _other} -> await_idle(session_id, timeout_ms)
    after
      timeout_ms ->
        _ = Sessions.cancel_turn(session_id)
        {:error, :timeout}
    end
  end

  defp summary(session_id) do
    session_id
    |> Sessions.history()
    |> Enum.filter(&(&1.role == "assistant"))
    |> List.last()
    |> case do
      nil ->
        ""

      %{content: content} when is_binary(content) ->
        binary_part(content, 0, min(byte_size(content), @summary_bytes))
    end
  end

  defp finish(run, task, session_id, summary) do
    {:ok, run} =
      Scheduler.update_run(run, %{
        status: "ok",
        session_id: session_id,
        summary: summary,
        error: nil,
        finished_at: DateTime.utc_now()
      })

    _ = Trinity.Repo.update(Ecto.Changeset.change(task, last_run_at: DateTime.utc_now()))

    case Delivery.for(task).deliver(run, task) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("task #{task.name}: delivery failed: #{inspect(reason)}")
    end

    :ok
  end

  defp fail(run, reason, attempt, max) do
    last? = attempt >= max
    text = describe(reason)

    {:ok, run} =
      Scheduler.update_run(run, %{
        status: if(last?, do: "failed", else: "retrying"),
        error: text,
        finished_at: if(last?, do: DateTime.utc_now())
      })

    if last?, do: deliver_failure(run)
    {:error, text}
  end

  defp deliver_failure(run) do
    case Scheduler.get_task(run.task_id) do
      %Task{} = task -> Delivery.for(task).deliver(run, task)
      nil -> :ok
    end
  end

  defp describe(:timeout), do: "the turn did not finish within the task's timeout"
  defp describe(:session_error), do: "the session ended the turn in error"
  defp describe({:turn, reason}), do: "the turn failed: " <> inspect(reason)

  defp describe(%Ecto.Changeset{} = cs),
    do: "the session could not be created: " <> inspect(cs.errors)

  defp describe(other), do: inspect(other)
end
