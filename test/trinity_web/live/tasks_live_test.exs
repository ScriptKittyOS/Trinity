# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.TasksLiveTest do
  @moduledoc "Slice 050: the tasks page lists, adds, edits, runs and removes tasks; the results list marks runs seen; /oban answers in dev."
  use TrinityWeb.ConnCase, async: false
  use Oban.Testing, repo: Trinity.Repo
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Trinity.SessionCase, only: [script_deltas: 2]

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Scheduler
  alias Trinity.Scheduler.Workers.RunTask

  setup do
    Fake.clear()
    on_exit(fn -> Trinity.SessionCase.stop_all_sessions() end)
    :ok
  end

  test "the form adds a task; the list shows it with its next run; a bad schedule shows its error; edit, disable, remove",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/tasks")

    view
    |> form("#task-form", %{
      "task" => %{
        "name" => "nightly",
        "kind" => "cron",
        "schedule" => "every night",
        "prompt" => "Summarise."
      }
    })
    |> render_submit()

    assert has_element?(view, "#task-form p", "schedule:")

    view
    |> form("#task-form", %{
      "task" => %{
        "name" => "nightly",
        "kind" => "cron",
        "schedule" => "0 2 * * *",
        "prompt" => "Summarise.",
        "skill_names" => "git-workflow, web-research"
      }
    })
    |> render_submit()

    assert [task] = Scheduler.list_tasks()
    assert task.skill_names == ["git-workflow", "web-research"]
    assert has_element?(view, "#task-#{task.id}", "nightly")
    assert has_element?(view, "#task-#{task.id}", "cron · 0 2 * * *")

    view |> element("#task-#{task.id} button", "edit") |> render_click()

    view
    |> form("#task-form", %{
      "task" => %{
        "name" => "nightly summary",
        "kind" => "cron",
        "schedule" => "0 2 * * *",
        "prompt" => "Summarise."
      }
    })
    |> render_submit()

    assert %{name: "nightly summary"} = Scheduler.get_task(task.id)

    view |> element("#task-#{task.id} button", "disable") |> render_click()
    assert has_element?(view, "#task-#{task.id}", "disabled")
    assert %{enabled: false} = Scheduler.get_task(task.id)

    view |> element("#task-#{task.id} button", "remove") |> render_click()
    refute has_element?(view, "#task-#{task.id}")
    assert [] = Scheduler.list_tasks()
  end

  test "run now queues a run; when it finishes the result is listed until marked seen; the run history shows it with its conversation",
       %{conn: conn} do
    {:ok, task} =
      Scheduler.create_task(%{
        name: "hello",
        kind: "cron",
        schedule: "@daily",
        prompt: "Say hello.",
        timeout_ms: 5_000
      })

    {:ok, view, _} = live(conn, ~p"/tasks")

    view |> element("#task-#{task.id} button", "run now") |> render_click()
    assert [run] = Scheduler.runs(task)
    assert_enqueued(worker: RunTask, args: %{"run_id" => run.id})

    Fake.scripts([script_deltas(2, "hi ")])

    assert :ok =
             perform_job(RunTask, %{
               "run_id" => run.id,
               "task_id" => task.id,
               "scheduled_at" => DateTime.to_iso8601(run.scheduled_at)
             })

    # The delivery's broadcast reloads the page.
    assert render(view) =~ "hi hi"
    assert has_element?(view, "#notification-#{run.id}", "hello")
    assert has_element?(view, "#unseen-runs", "1 result to read")

    view |> element("#notification-#{run.id} button", "seen") |> render_click()
    refute has_element?(view, "#notification-#{run.id}")
    refute has_element?(view, "#unseen-runs")

    view |> element("#task-#{task.id} button", "hello") |> render_click()
    assert has_element?(view, "#runs-#{task.id} td", "ok")
    assert has_element?(view, "#runs-#{task.id} a", "conversation")
  end

  test "the suggest form fills the schedule from the model's answer", %{conn: conn} do
    Fake.object(%{"cron" => "0 9 * * 1-5"})
    {:ok, view, _} = live(conn, ~p"/tasks")
    view |> form("#suggest-form", %{"phrase" => "every weekday at 9am"}) |> render_submit()
    assert has_element?(view, "#task-form input[name='task[schedule]'][value='0 9 * * 1-5']")
    assert has_element?(view, "#suggest-form span", "0 9 * * 1-5")
  end

  # The dashboard's LiveView waits for Oban.Met, which Oban does not start in the suite's
  # manual testing mode, so the mount is asserted on the router (the page itself is AC6's
  # screenshot, taken against the dev run).
  test "Oban Web is mounted at /oban" do
    assert %{plug: Phoenix.LiveView.Plug, phoenix_live_view: {Oban.Web.DashboardLive, _, _, _}} =
             Phoenix.Router.route_info(TrinityWeb.Router, "GET", "/oban", "localhost")
  end
end
