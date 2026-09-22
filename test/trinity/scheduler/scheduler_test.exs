# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SchedulerTest do
  @moduledoc """
  Slice 050 AC1 (a task with `*/5 * * * *` carries its next five-minute boundary; the tick at that
  time enqueues `RunTask` for it, once; `perform_job` runs it), AC2's automatic half (the run in a
  `cron` session, the summary, the delivery), AC3 (a failing turn retries, then the run is failed
  with the error), AC4 (the human schedule helper) and AC5 (a job survives a restart of Oban).
  """
  use Trinity.SessionCase
  use Oban.Testing, repo: Trinity.Repo
  @moduletag :capture_log

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Scheduler
  alias Trinity.Scheduler.{Parse, Run, Task}
  alias Trinity.Scheduler.Workers.{RunTask, Tick}

  defp task!(attrs \\ %{}) do
    {:ok, task} =
      Scheduler.create_task(
        Map.merge(
          %{
            name: "every five",
            kind: "cron",
            schedule: "*/5 * * * *",
            prompt: "Say hello.",
            timeout_ms: 5_000
          },
          attrs
        )
      )

    task
  end

  test "AC1: creating a task with */5 * * * * computes the next boundary; the tick at that time enqueues one RunTask, unique on task and time; perform_job runs it" do
    task = task!()
    assert %DateTime{minute: m, second: 0} = task.next_run_at
    assert rem(m, 5) == 0
    assert DateTime.compare(task.next_run_at, DateTime.utc_now()) == :gt

    # Not due yet: nothing enqueued.
    assert [] = Scheduler.enqueue_due(DateTime.add(task.next_run_at, -1, :second))
    refute_enqueued(worker: RunTask)

    # Due: the tick enqueues one run for that time and advances the task; a second tick for the
    # same minute enqueues nothing more.
    at = task.next_run_at
    assert {:ok, _} = perform_job(Tick, %{"now" => DateTime.to_iso8601(at)})

    assert_enqueued(
      worker: RunTask,
      args: %{"task_id" => task.id, "scheduled_at" => DateTime.to_iso8601(at)}
    )

    assert [%Run{status: "queued", scheduled_at: ^at}] = Scheduler.runs(task)
    assert {:ok, _} = perform_job(Tick, %{"now" => DateTime.to_iso8601(at)})
    assert [_one] = Scheduler.runs(task)
    assert [_one] = all_enqueued(worker: RunTask)

    advanced = Scheduler.get_task(task.id)
    assert DateTime.compare(advanced.next_run_at, at) == :gt
    assert advanced.next_run_at.minute == rem(at.minute + 5, 60)

    # The job runs: a FakeProvider turn.
    Fake.scripts([script_deltas(2, "hello ")])
    [%Run{id: run_id}] = Scheduler.runs(task)

    assert :ok =
             perform_job(RunTask, %{
               "run_id" => run_id,
               "task_id" => task.id,
               "scheduled_at" => DateTime.to_iso8601(at)
             })

    assert %Run{status: "ok", summary: "hello hello "} = Scheduler.get_run(run_id)
  end

  test "AC2 (automatic half): the run is a turn in a fresh cron session titled after the task; the run row carries the summary; the desktop delivery marks it and broadcasts" do
    :ok = Scheduler.subscribe()
    persona = Trinity.Factory.persona!()
    task = task!(%{name: "morning note", persona_id: persona.id, skill_names: ["git-workflow"]})
    Fake.scripts([script_deltas(3, "done ")])

    {:ok, run} = Scheduler.run_now(task)

    assert :ok =
             perform_job(RunTask, %{
               "run_id" => run.id,
               "task_id" => task.id,
               "scheduled_at" => DateTime.to_iso8601(run.scheduled_at)
             })

    run = Scheduler.get_run(run.id)

    assert %Run{status: "ok", summary: "done done done ", delivered_at: %DateTime{}, seen_at: nil} =
             run

    assert_receive {:task_run, %Run{id: rid}}, 1_000
    assert rid == run.id

    session = Sessions.get_session(run.session_id)

    assert %{
             origin: "cron",
             title: "morning note",
             persona_id: pid,
             origin_ref: %{"task_id" => tid}
           } = session

    assert pid == persona.id and tid == task.id

    assert [%{role: "user", content: content}, %{role: "assistant"}] =
             Sessions.history(run.session_id)

    assert content =~ "Say hello." and content =~ "git-workflow"

    assert [%Run{id: ^rid}] = Scheduler.unseen_runs()
    {:ok, _} = Scheduler.mark_seen(run)
    assert [] = Scheduler.unseen_runs()
    assert %{last_run_at: %DateTime{}} = Scheduler.get_task(task.id)
  end

  test "AC3: a failing turn is an error Oban retries; the run reads retrying, then failed with the error on the last attempt" do
    task = task!(%{name: "doomed"})
    {:ok, run} = Scheduler.run_now(task)

    args = %{
      "run_id" => run.id,
      "task_id" => task.id,
      "scheduled_at" => DateTime.to_iso8601(run.scheduled_at)
    }

    Fake.fail(10, Trinity.LLM.Error.permanent(:model_down))

    assert {:error, text} = perform_job(RunTask, args, attempt: 1)
    assert text =~ "the turn failed" or text =~ "error"
    assert %Run{status: "retrying", error: error} = Scheduler.get_run(run.id)
    assert is_binary(error)

    assert {:error, _} = perform_job(RunTask, args, attempt: 3)

    assert %Run{status: "failed", finished_at: %DateTime{}, delivered_at: %DateTime{}} =
             Scheduler.get_run(run.id)
  end

  test "AC4: the human schedule helper turns a phrase into cron through the model and refuses an answer that does not parse; a cron phrase passes through" do
    Fake.object(%{"cron" => "0 9 * * 1-5"})
    assert {:ok, "0 9 * * 1-5"} = Parse.human("every weekday at 9am")

    Fake.object(%{"cron" => "at nine on weekdays"})
    assert {:error, {:not_cron, "at nine on weekdays", _}} = Parse.human("every weekday at 9am")

    assert {:ok, "@daily"} = Parse.human("@daily")
    assert {:ok, "30 6 * * *"} = Parse.human(" 30 6 * * * ")
    assert {:error, :empty} = Parse.human("   ")
  end

  test "a one-shot task runs once at its time and is then disabled; a schedule that does not parse is refused" do
    at = DateTime.utc_now() |> DateTime.add(90, :second) |> DateTime.truncate(:second)
    task = task!(%{name: "once", kind: "once", schedule: DateTime.to_iso8601(at)})
    assert DateTime.compare(task.next_run_at, at) == :eq

    assert [] = Scheduler.enqueue_due(DateTime.add(at, -1, :second))
    assert [%Run{}] = Scheduler.enqueue_due(at)
    assert %Task{enabled: false, next_run_at: nil} = Scheduler.get_task(task.id)
    assert [] = Scheduler.enqueue_due(DateTime.add(at, 60, :second))

    assert {:error, cs} =
             Scheduler.create_task(%{
               name: "bad",
               kind: "cron",
               schedule: "every day",
               prompt: "x"
             })

    assert %{schedule: [msg]} = errors_on(cs)
    assert msg =~ "not a cron expression"

    assert {:error, cs} =
             Scheduler.create_task(%{
               name: "bad",
               kind: "once",
               schedule: "tomorrow",
               prompt: "x"
             })

    assert %{schedule: [_]} = errors_on(cs)
  end

  test "AC5: a job inserted before Oban stops runs after Oban starts again" do
    task = task!(%{name: "survivor"})
    Fake.scripts([script_deltas(1, "back ")])
    {:ok, run} = Scheduler.run_now(task)

    # The job is a row; a second Oban instance with a live queue picks it up after a restart.
    opts = [
      name: :oban_restart,
      repo: Trinity.Repo,
      engine: Application.fetch_env!(:trinity, Oban)[:engine],
      notifier: Oban.Notifiers.PG,
      testing: :disabled,
      queues: [agent_tasks: 1],
      plugins: false,
      stage_interval: 50,
      poll_interval: 50
    ]

    {:ok, pid} = Oban.start_link(opts)
    Ecto.Adapters.SQL.Sandbox.allow(Trinity.Repo, self(), pid)
    :ok = Supervisor.stop(pid)
    assert %Run{status: "queued"} = Scheduler.get_run(run.id)

    {:ok, pid} = Oban.start_link(opts)
    Ecto.Adapters.SQL.Sandbox.allow(Trinity.Repo, self(), pid)

    assert Enum.find_value(1..100, fn _ ->
             case Scheduler.get_run(run.id) do
               %Run{status: "ok"} = r -> r
               _ -> Process.sleep(50) && nil
             end
           end)

    Supervisor.stop(pid)
  end
end
