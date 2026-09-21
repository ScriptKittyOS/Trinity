# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SkillsLiveTest do
  @moduledoc "Slice 040: the /skills page lists with badges, views a body, disables and enables, reindexes, names what did not load."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Skills.Registry

  setup do
    old = Application.get_env(:trinity, :skills, [])

    on_exit(fn ->
      Application.put_env(:trinity, :skills, old)
      Registry.rescan()
    end)

    Registry.rescan()
    {:ok, old: old}
  end

  test "lists the skills with source badges and shadows, views one, disables and enables it, reindexes",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/skills")
    assert html =~ "echo-skill"
    assert has_element?(view, "#skill-echo-skill span[title=account]", "user")
    assert has_element?(view, "#skill-echo-skill", "shadows bundled")
    assert has_element?(view, "#skill-needs-missing-tool", "hidden: requirements")

    view |> element("#skill-echo-skill button", "echo-skill") |> render_click()
    assert has_element?(view, "#skill-view h2", "echo-skill")
    assert has_element?(view, "#skill-body", "The user's version wins")

    view |> element("#skill-echo-skill button", "disable") |> render_click()
    assert Trinity.Skills.get("echo-skill").status == "disabled"
    assert has_element?(view, "#skill-echo-skill button", "enable")
    view |> element("#skill-echo-skill button", "enable") |> render_click()
    assert Trinity.Skills.get("echo-skill").status == "active"

    view |> element("#reindex") |> render_click()
    assert render(view) =~ "Skills reindexed."
  end

  test "names the directories that did not load", %{conn: conn, old: old} do
    fixtures = Path.expand("../../support/fixtures/skills", __DIR__)

    Application.put_env(
      :trinity,
      :skills,
      Keyword.put(old, :user_dir, Path.join(fixtures, "bad"))
    )

    ExUnit.CaptureLog.capture_log(fn -> Registry.rescan() end)
    {:ok, view, _} = live(conn, ~p"/skills")
    assert has_element?(view, "#skill-errors li", "bad-name")
    assert has_element?(view, "#skill-errors li", "no-frontmatter")
    assert render(view) =~ "Not loaded"
  end
end
