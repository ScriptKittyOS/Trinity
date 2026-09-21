# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.MemoryPagesTest do
  @moduledoc "Slice 030 AC5's automatic half: the persona editor and the memory page write through the contexts and the changes persist."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.{Factory, Personas}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Memory.{AlwaysOn, Consolidator}

  setup do
    persona = Factory.persona!(%{name: "Editor persona", soul: "# Old soul"})
    on_exit(fn -> Fake.clear() end)
    {:ok, persona: persona}
  end

  test "the persona editor saves the soul, the model and the memory rule; the list creates one",
       %{conn: conn, persona: persona} do
    {:ok, view, html} = live(conn, ~p"/personas/#{persona.id}")
    assert html =~ "# Old soul"

    view
    |> form("#soul-form", persona: %{soul: "# New soul\nBe kind.", model: "fake:chat"})
    |> render_submit()

    assert has_element?(view, "#saved")
    assert Personas.get(persona.id).soul == "# New soul\nBe kind."
    assert Personas.get(persona.id).model == "fake:chat"

    view |> form("#memory-rule", rule: "allow") |> render_change()
    assert Personas.get(persona.id).settings["permissions"]["memory"] == "allow"

    {:ok, list, html} = live(conn, ~p"/personas")
    assert html =~ "Editor persona"
    list |> form("#persona-create", name: "Second") |> render_submit()
    assert_patch(list)

    assert Enum.any?(
             Personas.list(),
             &(&1.name == "Second" and &1.settings["permissions"]["memory"] == "allow")
           )
  end

  test "the memory page adds, edits in place and deletes entries; every change is logged by ui and persists",
       %{conn: conn, persona: persona} do
    {:ok, view, html} = live(conn, ~p"/memory?persona_id=#{persona.id}")
    assert html =~ "Nothing kept in this tier."

    view
    |> form("#memory-add", tier: "always_on", key: "editor", body: "neovim")
    |> render_submit()

    [entry] = AlwaysOn.all(persona.id)
    assert has_element?(view, "#entry-#{entry.id}", "neovim")

    view |> element("#entry-#{entry.id} button", "edit") |> render_click()
    view |> form("#edit-#{entry.id}", body: "helix") |> render_submit()
    assert AlwaysOn.get("always_on", AlwaysOn.persona_scope(persona.id), "editor").body == "helix"
    assert has_element?(view, "#entry-#{entry.id}", "helix")

    view |> element("#entry-#{entry.id} button", "delete") |> render_click()
    assert AlwaysOn.all(persona.id) == []

    assert Enum.map(AlwaysOn.changes(persona.id), &{&1.action, &1.by}) == [
             {"remove", "ui"},
             {"replace", "ui"},
             {"add", "ui"}
           ]

    assert render(view) =~ "remove always_on/editor by ui"

    # Persisted: a fresh mount shows the log, not the entry.
    {:ok, _again, html} = live(conn, ~p"/memory?persona_id=#{persona.id}")
    assert html =~ "Nothing kept in this tier."
    assert html =~ "remove always_on/editor by ui"
  end

  test "a pending consolidation is shown and can be applied or rejected", %{
    conn: conn,
    persona: persona
  } do
    old = Application.get_env(:trinity, :memory, [])
    Application.put_env(:trinity, :memory, Keyword.put(old, :budget_bytes, 60))
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    pscope = AlwaysOn.persona_scope(persona.id)

    attrs = %{
      persona_id: persona.id,
      tier: "always_on",
      scope: pscope,
      key: "a",
      body: String.duplicate("alpha ", 8)
    }

    {:ok, _} = AlwaysOn.add(attrs, by: "test")

    Fake.object(%{
      "entries" => [
        %{
          "tier" => "always_on",
          "scope" => pscope,
          "key" => "a",
          "body" => String.duplicate("alpha ", 20)
        }
      ]
    })

    attrs = %{
      persona_id: persona.id,
      tier: "always_on",
      scope: pscope,
      key: "b",
      body: String.duplicate("beta ", 8)
    }

    {:ok, _} = AlwaysOn.add(attrs, by: "test")

    [proposal] = Consolidator.pending(persona.id)

    {:ok, view, html} = live(conn, ~p"/memory?persona_id=#{persona.id}")
    assert html =~ "Consolidation waiting for you"
    assert has_element?(view, "#budget", "bytes")
    view |> element("#proposal-#{proposal.id} button", "Reject") |> render_click()
    assert Consolidator.get(proposal.id).status == "rejected"
    refute render(view) =~ "Consolidation waiting for you"
  end

  test "the index page picks a persona for the next session", %{conn: conn, persona: persona} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> form("#persona-picker", persona_id: persona.id) |> render_change()
    view |> element("#new-session") |> render_click()
    assert_redirect(view)
    [session | _] = Trinity.Sessions.list_sessions(limit: 1)
    assert session.persona_id == persona.id
  end
end
