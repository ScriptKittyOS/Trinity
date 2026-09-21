# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SkillsLive do
  @moduledoc """
  `/skills` (slice 040): every skill the registry found, with its source and scope badges,
  its version and status, the shadowed sources, a view of one skill's body and files,
  enable and disable (persisted on the index row), the reindex button, and the directories
  that did not load with their reasons. Project skills are shown for the project root given
  as `?project=<dir>`, since a project's skills belong to sessions of that project.
  """
  use TrinityWeb, :live_view

  alias Trinity.Skills
  alias Trinity.Skills.{Manager, Registry, Staging}

  @impl true
  def mount(params, _session, socket) do
    project = params["project"]

    {:ok,
     socket
     |> assign(
       page_title: gettext("Skills"),
       project: project,
       viewing: nil,
       showing: nil,
       learning: nil
     )
     |> load()}
  end

  defp load(%{assigns: %{project: project}} = socket) do
    skills = Skills.list(project_root: project)
    active = Skills.active(project_root: project) |> MapSet.new(& &1.name)

    assign(socket,
      skills: skills,
      active: active,
      errors: Registry.errors(),
      pending: Staging.list(),
      recent: Staging.list(status: "applied") |> Enum.take(-5),
      viewing:
        socket.assigns.viewing && Enum.find(skills, &(&1.name == socket.assigns.viewing.name))
    )
  end

  # Slice 041: the staged changes.
  @impl true
  def handle_event("show_change", %{"id" => id}, socket) do
    {:noreply, assign(socket, showing: Enum.find(socket.assigns.pending, &(&1.id == id)))}
  end

  def handle_event("hide_change", _params, socket), do: {:noreply, assign(socket, showing: nil)}

  def handle_event("approve_change", %{"change_id" => id} = params, socket) do
    with %{} = change <- Staging.get(id),
         {:ok, _} <- Manager.approve(change, by: "ui", comment: blank_to_nil(params["comment"])) do
      {:noreply,
       socket
       |> assign(showing: nil)
       |> load()
       |> put_flash(:info, gettext("Applied %{name}.", name: change.skill_name))}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("No such change."))}

      {:error, reason} ->
        {:noreply,
         socket |> load() |> put_flash(:error, gettext("Not applied: %{r}", r: inspect(reason)))}
    end
  end

  def handle_event("reject_change", %{"id" => id} = params, socket) do
    with %{} = change <- Staging.get(id),
         {:ok, _} <- Manager.reject(change, by: "ui", comment: blank_to_nil(params["comment"])) do
      {:noreply,
       socket |> assign(showing: nil) |> load() |> put_flash(:info, gettext("Rejected."))}
    else
      _ -> {:noreply, socket |> load() |> put_flash(:error, gettext("Not rejected."))}
    end
  end

  # The learn form: a URL or a file under the project's roots, distilled by the default
  # persona's model, staged like any change. The model call takes a while, so it runs as
  # the view's async task (a blocked view misses its heartbeats and the client reconnects).
  def handle_event("learn", %{"source" => source}, socket) do
    source = String.trim(source)
    persona = Trinity.Personas.default()
    project = socket.assigns.project

    args =
      if String.match?(source, ~r/^https?:\/\//),
        do: %{"url" => source},
        else: %{"file" => source}

    {:noreply,
     socket
     |> assign(learning: source)
     |> start_async(:learn, fn -> Skills.Learn.learn_for(args, project, persona) end)}
  end

  @impl true
  def handle_async(:learn, {:ok, {:ok, change}}, socket) do
    {:noreply,
     socket
     |> assign(learning: nil)
     |> load()
     |> put_flash(
       :info,
       gettext("Staged the learned skill %{name} for your approval.", name: change.skill_name)
     )}
  end

  def handle_async(:learn, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(learning: nil)
     |> put_flash(:error, gettext("Nothing learned: %{r}", r: inspect(reason)))}
  end

  def handle_async(:learn, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(learning: nil)
     |> put_flash(:error, gettext("Nothing learned: %{r}", r: inspect(reason)))}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:bar>
        <span class="opacity-70">{gettext("Skills")}</span>
        <span class="font-mono text-meta opacity-70">{length(@skills)}</span>
        <button id="reindex" phx-click="reindex" class="btn btn-xs btn-ghost">{gettext("reindex")}</button>
      </:bar>
      <div
        id="skills"
        phx-hook="Shortcuts"
        class="mx-auto flex h-full max-w-4xl flex-col gap-6 overflow-y-auto px-4 py-6"
      >
        <p :if={@project} class="font-mono text-meta opacity-70">{gettext("project")}: {@project}</p>
        <section :if={@errors != []} class="flex flex-col gap-1">
          <h2 class="text-ui font-semibold text-error">{gettext("Not loaded")}</h2>
          <ul id="skill-errors" class="font-mono text-meta">
            <li :for={e <- @errors}>{e.dir} ({e.source}): {inspect(e.reason)}</li>
          </ul>
        </section>

        <section id="pending-changes" class="flex flex-col gap-2">
          <h2 class="text-lg font-semibold">
            {gettext("Pending changes")}
            <span class="font-mono text-meta opacity-70">{length(@pending)}</span>
          </h2>
          <p :if={@pending == []} class="opacity-70">{gettext("Nothing waiting for a decision.")}</p>
          <ul class="flex flex-col gap-1">
            <li
              :for={c <- @pending}
              id={"change-#{c.id}"}
              class="flex items-center gap-2 rounded-field border border-base-300 px-3 py-2 text-ui"
            >
              <span class={["rounded-pill px-2 font-mono text-meta", severity_class(c.severity)]}>{c.severity}</span>
              <span class="font-mono">{c.action}</span>
              <button phx-click="show_change" phx-value-id={c.id} class="link font-mono font-semibold">{c.skill_name}</button>
              <span class="flex-1 opacity-80">{c.rationale}</span>
              <span :if={c.destructive} class="font-mono text-meta text-warning">{gettext(
                "destructive"
              )}</span>
              <span class="font-mono text-meta opacity-60">{Calendar.strftime(
                c.inserted_at,
                "%Y-%m-%d %H:%M"
              )}</span>
            </li>
          </ul>

          <div
            :if={@showing}
            id="change-view"
            class="flex flex-col gap-2 rounded-field border border-base-300 px-3 py-2"
          >
            <div class="flex items-center gap-2">
              <h3 class="font-mono text-lg font-semibold">{@showing.action} {@showing.skill_name}</h3>
              <span class={[
                "rounded-pill px-2 font-mono text-meta",
                severity_class(@showing.severity)
              ]}>{@showing.severity}</span>
              <span class="font-mono text-meta opacity-60">{@showing.id}</span>
              <span class="flex-1"></span>
              <button phx-click="hide_change" class="btn btn-xs btn-ghost">{gettext("close")}</button>
            </div>
            <p class="opacity-80">{@showing.rationale}</p>
            <p :if={@showing.severity == "high"} id="high-note" class="text-warning">
              {gettext("High severity: never auto-approved. Read the findings before approving.")}
            </p>
            <h4 class="text-ui font-semibold">{gettext("Findings")}</h4>
            <p :if={findings(@showing) == []} class="opacity-70">{gettext("None.")}</p>
            <ul id="findings" class="font-mono text-meta">
              <li :for={f <- findings(@showing)}>
                [{f["severity"]}] {f["rule"]} {f["file"]}:{f["line"]} {f["match"]}
              </li>
            </ul>
            <h4 class="text-ui font-semibold">{gettext("Diff")}</h4>
            <pre
              id="change-diff"
              class="whitespace-pre-wrap rounded-field bg-base-200 p-3 font-mono text-meta"
            >{@showing.diff}</pre>
            <form id="decide-change" phx-submit="approve_change" class="flex items-center gap-2">
              <input type="hidden" name="change_id" value={@showing.id} />
              <input
                name="comment"
                placeholder={gettext("comment (optional)")}
                class="flex-1 rounded-field border border-base-300 bg-base-100 px-2 py-2 text-ui"
              />
              <button type="submit" class="btn btn-sm btn-primary">{gettext("Approve and apply")}</button>
              <button
                type="button"
                phx-click="reject_change"
                phx-value-id={@showing.id}
                data-confirm={gettext("Reject this change? Its staged files are removed.")}
                class="btn btn-sm btn-ghost text-error"
              >{gettext("Reject")}</button>
            </form>
          </div>

          <form id="learn-form" phx-submit="learn" class="flex items-center gap-2">
            <input
              name="source"
              placeholder={gettext("learn from a file under the project, or a URL")}
              class="flex-1 rounded-field border border-base-300 bg-base-100 px-2 py-2 text-ui"
            />
            <button type="submit" class="btn btn-sm btn-ghost" disabled={@learning != nil}>{gettext(
              "Learn"
            )}</button>
            <span :if={@learning} id="learning" class="font-mono text-meta opacity-70">
              {gettext("learning from")} {@learning}…
            </span>
          </form>

          <ul :if={@recent != []} id="recent-changes" class="font-mono text-meta opacity-70">
            <li :for={c <- @recent}>
              {gettext("applied")} {c.action} {c.skill_name} v{c.applied_version || "-"} {gettext(
                "by"
              )} {c.decided_by}
            </li>
          </ul>
        </section>

        <p :if={@skills == []} class="opacity-70">{gettext("No skills found under any root.")}</p>
        <ul class="flex flex-col gap-1">
          <li
            :for={s <- @skills}
            id={"skill-#{s.name}"}
            class={[
              "flex items-start gap-2 rounded-field border border-base-300 px-3 py-2 text-ui",
              s.status != "active" && "opacity-60"
            ]}
          >
            <span class="rounded-pill bg-base-300 px-2 font-mono text-meta" title={s.scope}>{s.source}</span>
            <span class="font-mono text-meta opacity-70">v{s.version}</span>
            <button phx-click="view" phx-value-name={s.name} class="link font-mono font-semibold">{s.name}</button>
            <span class="flex-1 opacity-80">{Trinity.Skills.Skill.one_line(s)}</span>
            <span
              :if={s.shadows != []}
              class="font-mono text-meta opacity-60"
              title={gettext("shadows")}
            >
              {gettext("shadows")} {Enum.join(s.shadows, ", ")}
            </span>
            <span
              :if={s.status == "active" and not MapSet.member?(@active, s.name)}
              class="font-mono text-meta text-warning"
              title={gettext("its tools or toolsets are not registered")}
            >
              {gettext("hidden: requirements")}
            </span>
            <button
              :if={s.status == "active"}
              phx-click="set_status"
              phx-value-name={s.name}
              phx-value-source={s.source}
              phx-value-status="disabled"
              class="btn btn-xs btn-ghost"
            >{gettext("disable")}</button>
            <button
              :if={s.status != "active"}
              phx-click="set_status"
              phx-value-name={s.name}
              phx-value-source={s.source}
              phx-value-status="active"
              class="btn btn-xs btn-ghost"
            >{gettext("enable")}</button>
          </li>
        </ul>

        <section
          :if={@viewing}
          id="skill-view"
          class="flex flex-col gap-2 rounded-field border border-base-300 px-3 py-2"
        >
          <div class="flex items-center gap-2">
            <h2 class="font-mono text-lg font-semibold">{@viewing.name}</h2>
            <span class="font-mono text-meta opacity-70">{@viewing.path}</span>
            <span class="flex-1"></span>
            <button phx-click="close" class="btn btn-xs btn-ghost">{gettext("close")}</button>
          </div>
          <p class="opacity-80">{@viewing.description}</p>
          <dl class="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-1 font-mono text-meta">
            <dt>{gettext("category")}</dt>
            <dd>{@viewing.category}</dd>
            <dt>{gettext("license")}</dt>
            <dd>{@viewing.license || "-"}</dd>
            <dt>{gettext("compatibility")}</dt>
            <dd>{@viewing.compatibility || "-"}</dd>
            <dt>{gettext("body digest")}</dt>
            <dd>{@viewing.body_hash}</dd>
            <dt>{gettext("trinity")}</dt>
            <dd>{inspect(@viewing.trinity)}</dd>
            <dt>{gettext("files")}</dt>
            <dd>{Enum.join(@viewing.references ++ @viewing.scripts, ", ")}</dd>
          </dl>
          <pre
            id="skill-body"
            class="whitespace-pre-wrap rounded-field bg-base-200 p-3 font-mono text-meta"
          >{@viewing.body}</pre>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp findings(%{findings: %{"findings" => list}}) when is_list(list), do: list
  defp findings(_), do: []

  defp severity_class("high"), do: "bg-error/20 text-error"
  defp severity_class("medium"), do: "bg-warning/20 text-warning"
  defp severity_class(_), do: "bg-base-300"
end
