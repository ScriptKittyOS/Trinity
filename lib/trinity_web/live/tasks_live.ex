# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.TasksLive do
  @moduledoc """
  `/tasks` (slice 050): the scheduled tasks with their next and last runs, run now, enable,
  disable and remove; a form to add or edit one (a schedule as cron or a one-shot datetime,
  with a "suggest" that asks the model to turn a phrase into cron); the notifications list
  (finished runs the owner has not seen, with their summaries and links to their sessions);
  and each task's run history. Everything here is `Trinity.Scheduler`.
  """
  use TrinityWeb, :live_view

  alias Trinity.Scheduler
  alias Trinity.Scheduler.{Parse, Task}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Scheduler.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Tasks"),
       editing: nil,
       form: new_form(),
       viewing: nil,
       suggestion: nil
     )
     |> load()}
  end

  defp new_form(attrs \\ %{"kind" => "cron", "timeout_ms" => "600000", "enabled" => "true"}),
    do: to_form(attrs, as: :task)

  defp load(socket) do
    assign(socket,
      tasks: Scheduler.list_tasks(),
      unseen: Scheduler.unseen_runs(),
      personas: Trinity.Personas.list(),
      runs: if(socket.assigns[:viewing], do: Scheduler.runs(socket.assigns.viewing), else: [])
    )
  end

  @impl true
  def handle_info({:task_run, _run}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save", %{"task" => params}, socket) do
    attrs = attrs(params)

    result =
      case socket.assigns.editing do
        nil -> Scheduler.create_task(attrs)
        %Task{} = task -> Scheduler.update_task(task, attrs)
      end

    case result do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign(editing: nil, form: new_form(), suggestion: nil)
         |> put_flash(:info, gettext("Task %{name} saved.", name: task.name))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(params, as: :task, errors: errors(changeset)))}
    end
  end

  def handle_event("change", %{"task" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(params, as: :task))}

  def handle_event("suggest", %{"phrase" => phrase}, socket) do
    case Parse.human(phrase) do
      {:ok, cron} ->
        params =
          socket.assigns.form.params |> Map.put("schedule", cron) |> Map.put("kind", "cron")

        {:noreply, assign(socket, form: to_form(params, as: :task), suggestion: cron)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No schedule from that: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Scheduler.get_task(id) do
      nil ->
        {:noreply, socket}

      task ->
        params = %{
          "name" => task.name,
          "kind" => task.kind,
          "schedule" => task.schedule,
          "prompt" => task.prompt,
          "persona_id" => task.persona_id,
          "skill_names" => Enum.join(task.skill_names, ", "),
          "timeout_ms" => Integer.to_string(task.timeout_ms),
          "enabled" => to_string(task.enabled)
        }

        {:noreply, assign(socket, editing: task, form: to_form(params, as: :task))}
    end
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing: nil, form: new_form())}

  def handle_event("run_now", %{"id" => id}, socket) do
    with %Task{} = task <- Scheduler.get_task(id), {:ok, _run} <- Scheduler.run_now(task) do
      {:noreply, socket |> put_flash(:info, gettext("Run queued.")) |> load()}
    else
      {:error, :already_scheduled} ->
        {:noreply, put_flash(socket, :error, gettext("A run for this moment is already queued."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not queued."))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %Task{} = task <- Scheduler.get_task(id),
         {:ok, _} <- Scheduler.update_task(task, %{enabled: !task.enabled}) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not changed."))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    with %Task{} = task <- Scheduler.get_task(id), {:ok, _} <- Scheduler.delete_task(task) do
      {:noreply, socket |> assign(viewing: nil) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not removed."))}
    end
  end

  def handle_event("view", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(viewing: id) |> load()}

  def handle_event("hide", _params, socket),
    do: {:noreply, socket |> assign(viewing: nil) |> load()}

  def handle_event("seen", %{"id" => id}, socket) do
    _ = Scheduler.mark_seen(id)
    {:noreply, load(socket)}
  end

  def handle_event("seen_all", _params, socket) do
    for run <- socket.assigns.unseen, do: Scheduler.mark_seen(run)
    {:noreply, load(socket)}
  end

  # The form's strings to the row's attributes: skills split on commas, blanks dropped, the
  # persona nil when unset.
  defp attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      kind: params["kind"] || "cron",
      schedule: String.trim(params["schedule"] || ""),
      prompt: params["prompt"] || "",
      persona_id: blank_to_nil(params["persona_id"]),
      skill_names: (params["skill_names"] || "") |> String.split(~r/[\s,]+/, trim: true),
      timeout_ms: to_int(params["timeout_ms"], 600_000),
      enabled: params["enabled"] in ["true", "on", true]
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  defp to_int(nil, default), do: default

  defp to_int(s, default) do
    case Integer.parse(String.trim(s)) do
      {i, ""} -> i
      _ -> default
    end
  end

  defp errors(changeset), do: for({field, {msg, _}} <- changeset.errors, do: {field, {msg, []}})

  defp stamp(nil), do: gettext("never")
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Tasks")}</span>
        <span class="font-mono text-meta opacity-70">{length(@tasks)}</span>
        <span
          :if={@unseen != []}
          id="unseen-runs"
          class="rounded-pill bg-info/20 px-2 py-0.5 text-meta text-info"
        >
          {ngettext("%{count} result to read", "%{count} results to read", length(@unseen))}
        </span>
      </:bar>
      <div
        id="tasks"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-4xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <section :if={@unseen != []} id="notifications" class="flex flex-col gap-2">
          <div class="flex items-center gap-2">
            <h2 class="text-lg font-semibold">{gettext("Results")}</h2>
            <button phx-click="seen_all" class="btn btn-xs btn-ghost">{gettext("mark all seen")}</button>
          </div>
          <ul class="flex flex-col gap-2">
            <li
              :for={r <- @unseen}
              id={"notification-#{r.id}"}
              class={[
                "rounded-field border px-3 py-2",
                r.status == "ok" && "border-info/40 bg-info/5",
                r.status == "failed" && "border-error/40 bg-error/5"
              ]}
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-semibold">{r.task.name}</span>
                <span class="font-mono text-meta opacity-70">{stamp(r.finished_at)}</span>
                <span class={[
                  "rounded-pill px-2 py-0.5 text-meta",
                  r.status == "ok" && "bg-success/20 text-success",
                  r.status == "failed" && "bg-error/20 text-error"
                ]}>{r.status}</span>
                <span class="flex-1"></span>
                <.link
                  :if={r.session_id}
                  navigate={~p"/s/#{r.session_id}"}
                  class="text-meta opacity-70 hover:opacity-100"
                >{gettext("open the conversation")}</.link>
                <button phx-click="seen" phx-value-id={r.id} class="btn btn-xs btn-ghost">{gettext(
                  "seen"
                )}</button>
              </div>
              <p class="mt-1 whitespace-pre-wrap text-ui">{r.summary || r.error}</p>
            </li>
          </ul>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">{gettext("Scheduled tasks")}</h2>
          <p :if={@tasks == []} class="opacity-70">
            {gettext("No task yet. Add one below: a prompt, and when to run it.")}
          </p>
          <ul id="task-list" class="flex flex-col gap-2">
            <li
              :for={t <- @tasks}
              id={"task-#{t.id}"}
              class="flex flex-col gap-2 rounded-field border border-base-300 px-3 py-2"
            >
              <div class="flex flex-wrap items-center gap-2">
                <button type="button" phx-click="view" phx-value-id={t.id} class="font-semibold">{t.name}</button>
                <span class="font-mono text-meta opacity-70">{t.kind} · {t.schedule}</span>
                <span :if={!t.enabled} class="rounded-pill bg-base-300 px-2 py-0.5 text-meta">{gettext(
                  "disabled"
                )}</span>
                <span class="flex-1"></span>
                <button phx-click="run_now" phx-value-id={t.id} class="btn btn-xs btn-primary">{gettext(
                  "run now"
                )}</button>
                <button phx-click="edit" phx-value-id={t.id} class="btn btn-xs btn-ghost">{gettext(
                  "edit"
                )}</button>
                <button phx-click="toggle" phx-value-id={t.id} class="btn btn-xs btn-ghost">{if t.enabled,
                  do: gettext("disable"),
                  else: gettext("enable")}</button>
                <button
                  phx-click="remove"
                  phx-value-id={t.id}
                  data-confirm={gettext("Remove this task and its runs?")}
                  class="btn btn-xs btn-ghost text-error"
                >{gettext("remove")}</button>
              </div>
              <p class="text-meta opacity-70">
                {gettext("next")}: {stamp(t.next_run_at)} · {gettext("last")}: {stamp(t.last_run_at)}
              </p>
              <div :if={@viewing == t.id} class="flex flex-col gap-1 border-t border-base-300 pt-2">
                <div class="flex items-center gap-2">
                  <span class="text-meta opacity-70">{gettext("Runs")}</span>
                  <button phx-click="hide" class="btn btn-xs btn-ghost">{gettext("hide")}</button>
                </div>
                <p :if={@runs == []} class="text-meta opacity-70">{gettext("None yet.")}</p>
                <table :if={@runs != []} id={"runs-#{t.id}"} class="w-full text-ui">
                  <tbody>
                    <tr :for={r <- @runs} class="border-t border-base-300 align-top">
                      <td class="py-1 pr-3 whitespace-nowrap font-mono text-meta">
                        {stamp(r.scheduled_at)}
                      </td>
                      <td class="py-1 pr-3">
                        <span class={[
                          "rounded-pill px-2 py-0.5 text-meta",
                          r.status == "ok" && "bg-success/20 text-success",
                          r.status == "failed" && "bg-error/20 text-error",
                          r.status in ["queued", "running", "retrying"] &&
                            "bg-warning/20 text-warning"
                        ]}>{r.status}</span>
                      </td>
                      <td class="py-1 pr-3 text-meta">
                        <div class="truncate" title={r.summary || r.error}>
                          {r.summary || r.error}
                        </div>
                      </td>
                      <td class="py-1 text-meta">
                        <.link
                          :if={r.session_id}
                          navigate={~p"/s/#{r.session_id}"}
                          class="opacity-70 hover:opacity-100"
                        >{gettext("conversation")}</.link>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </li>
          </ul>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">
            {if @editing,
              do: gettext("Edit %{name}", name: @editing.name),
              else: gettext("Add a task")}
          </h2>
          <.form
            for={@form}
            id="task-form"
            phx-change="change"
            phx-submit="save"
            class="flex flex-col gap-2"
          >
            <div class="flex flex-wrap gap-2">
              <input
                name="task[name]"
                value={@form[:name].value}
                placeholder={gettext("name")}
                class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
              />
              <select
                name="task[persona_id]"
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
              >
                <option value="">{gettext("default persona")}</option>
                <option :for={p <- @personas} value={p.id} selected={@form[:persona_id].value == p.id}>
                  {p.name}
                </option>
              </select>
            </div>
            <div class="flex flex-wrap gap-2">
              <select
                name="task[kind]"
                class="rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
              >
                <option :for={k <- Task.kinds()} value={k} selected={@form[:kind].value == k}>
                  {k}
                </option>
              </select>
              <input
                name="task[schedule]"
                value={@form[:schedule].value}
                placeholder={gettext("cron (0 9 * * 1-5) or an ISO datetime for once")}
                class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
            </div>
            <textarea
              name="task[prompt]"
              rows="3"
              placeholder={gettext("the prompt to run")}
              class="rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
            >{@form[:prompt].value}</textarea>
            <div class="flex flex-wrap gap-2">
              <input
                name="task[skill_names]"
                value={@form[:skill_names].value}
                placeholder={gettext("skills to hint, comma separated")}
                class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
              <input
                name="task[timeout_ms]"
                value={@form[:timeout_ms].value}
                placeholder={gettext("timeout ms")}
                class="w-32 rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-ui"
              />
              <label class="flex items-center gap-2 text-ui"><input
                type="checkbox"
                name="task[enabled]"
                value="true"
                checked={@form[:enabled].value in ["true", true]}
                class="checkbox"
              /> {gettext("enabled")}</label>
            </div>
            <p :for={{field, {msg, _}} <- @form.errors} class="text-meta text-error">
              {field}: {msg}
            </p>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">{if @editing,
                do: gettext("Save"),
                else: gettext("Add")}</button>
              <button
                :if={@editing}
                type="button"
                phx-click="cancel_edit"
                class="btn btn-sm btn-ghost"
              >{gettext("Cancel")}</button>
            </div>
          </.form>
          <form id="suggest-form" phx-submit="suggest" class="flex items-center gap-2">
            <input
              name="phrase"
              placeholder={gettext("or say when: every weekday at 9am")}
              class="flex-1 rounded-field border border-base-300 bg-base-100 px-3 py-2 text-ui"
            />
            <button type="submit" class="btn btn-sm btn-ghost">{gettext("suggest a schedule")}</button>
            <span :if={@suggestion} class="font-mono text-meta">{@suggestion}</span>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
