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
  alias Trinity.Skills.Registry

  @impl true
  def mount(params, _session, socket) do
    project = params["project"]

    {:ok,
     socket |> assign(page_title: gettext("Skills"), project: project, viewing: nil) |> load()}
  end

  defp load(%{assigns: %{project: project}} = socket) do
    skills = Skills.list(project_root: project)
    active = Skills.active(project_root: project) |> MapSet.new(& &1.name)

    assign(socket,
      skills: skills,
      active: active,
      errors: Registry.errors(),
      viewing:
        socket.assigns.viewing && Enum.find(skills, &(&1.name == socket.assigns.viewing.name))
    )
  end

  @impl true
  def handle_event("view", %{"name" => name}, socket) do
    {:noreply, assign(socket, viewing: Enum.find(socket.assigns.skills, &(&1.name == name)))}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, viewing: nil)}

  def handle_event(
        "set_status",
        %{"name" => name, "source" => source, "status" => status},
        socket
      ) do
    case Skills.set_status(name, source, status) do
      :ok ->
        {:noreply, load(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gettext("Not changed: %{r}", r: inspect(reason)))}
    end
  end

  def handle_event("reindex", _params, socket) do
    :ok = Skills.rescan()
    {:noreply, socket |> load() |> put_flash(:info, gettext("Skills reindexed."))}
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, TrinityWeb.SessionLive.Index.new_session(socket)}

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

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
end
