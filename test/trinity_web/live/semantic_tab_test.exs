# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SemanticTabTest do
  @moduledoc "Slice 032, G1 line 7: the memory page's Semantic tab: status, search with provenance, delete, pin, and the download action shown only when the local model is missing."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.{Factory, Sessions}
  alias Trinity.Memory.{AlwaysOn, Semantic}

  setup do
    persona = Factory.persona!(%{name: "Semantic persona"})
    past = Factory.session!(%{persona_id: persona.id, title: "Earlier"})

    {:ok, source} =
      Sessions.append_message(past.id, %{role: "user", content: "near dog: my dog is called Rex"})

    pscope = AlwaysOn.persona_scope(persona.id)

    attrs = %{
      persona_id: persona.id,
      scope: pscope,
      key: "dog",
      body: "#near:dog has a dog named Rex",
      source_message_id: source.id,
      confidence: 0.9
    }

    {:ok, entry} = Semantic.add(attrs, by: "observer")

    {:ok, persona: persona, past: past, entry: entry, pscope: pscope}
  end

  test "the tab lists the tier with the status line, recalls with provenance links, deletes and pins",
       %{conn: conn, persona: persona, past: past, entry: entry, pscope: pscope} do
    {:ok, view, html} = live(conn, ~p"/memory?persona_id=#{persona.id}")
    refute html =~ "semantic recall is on"
    assert html =~ "Nothing kept in this tier."

    view |> element("#tab-semantic") |> render_click()
    assert_patch(view, ~p"/memory?persona_id=#{persona.id}&tab=semantic")
    html = render(view)
    assert html =~ "semantic recall is on (fake:sha256-384)"
    refute html =~ "Download the model"
    refute html =~ "Nothing kept in this tier."
    assert has_element?(view, "#semantic-#{entry.id}", "has a dog named Rex")
    assert has_element?(view, "#semantic-#{entry.id} a[href='/s/#{past.id}']", "source")

    view |> form("#semantic-search", query: "#near:dog my dog") |> render_submit()
    assert has_element?(view, "#hit-memory-#{entry.id}", "vector")
    assert has_element?(view, "#hit-memory-#{entry.id} a[href='/s/#{past.id}']", "source")

    assert has_element?(
             view,
             "#semantic-hits li[id^='hit-message-'] a[href='/s/#{past.id}']",
             "Earlier"
           )

    assert has_element?(view, "#semantic-hits li[id^='hit-message-']", "fts")

    view |> form("#semantic-search", query: "zzz") |> render_submit()
    assert render(view) =~ "Nothing recalled."

    view |> element("#semantic-#{entry.id} button", "pin") |> render_click()
    assert Semantic.all(persona.id) == []
    [pinned] = AlwaysOn.all(persona.id)

    assert {pinned.tier, pinned.scope, pinned.key, pinned.body} ==
             {"always_on", pscope, "dog", "#near:dog has a dog named Rex"}

    assert pinned.source_message_id == entry.source_message_id

    assert Enum.map(AlwaysOn.changes(persona.id), &{&1.action, &1.tier, &1.by}) == [
             {"pin", "semantic", "ui"},
             {"add", "always_on", "ui"},
             {"add", "semantic", "observer"}
           ]

    assert render(view) =~ "Nothing in the semantic tier yet"

    {:ok, _} =
      Semantic.add(%{persona_id: persona.id, scope: pscope, key: "cat", body: "has a cat"},
        by: "test"
      )

    view |> element("#tab-semantic") |> render_click()
    [cat] = Semantic.all(persona.id)
    view |> element("#semantic-#{cat.id} button", "delete") |> render_click()
    assert Semantic.all(persona.id) == []
    assert hd(AlwaysOn.changes(persona.id)).action == "remove"

    # Pinning a key the always-on tier holds is refused with a flash, not a crash.
    {:ok, dup} =
      Semantic.add(%{persona_id: persona.id, scope: pscope, key: "dog", body: "dog again"},
        by: "test"
      )

    view |> element("#tab-semantic") |> render_click()
    view |> element("#semantic-#{dup.id} button", "pin") |> render_click()
    assert render(view) =~ "already always in mind"
    assert length(Semantic.all(persona.id)) == 1
  end

  test "with the local model missing the tab says the tier is unavailable and offers the download; nothing is downloaded without the click",
       %{conn: conn, persona: persona} do
    old = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    cache = Path.join(System.tmp_dir!(), "no-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(cache) end)

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(old, embedder: :local, model_cache_dir: cache)
    )

    {:ok, view, _} = live(conn, ~p"/memory?persona_id=#{persona.id}&tab=semantic")
    html = render(view)

    case :os.type() do
      {:win32, _} ->
        assert html =~ "no local embedding backend yet"
        refute has_element?(view, "#model-download")

      _ ->
        assert html =~ "semantic recall is unavailable: the local model is not downloaded"
        assert html =~ "Full-text search still works."
        assert has_element?(view, "#model-download button", "Download the model")
    end

    # The offline check creates the empty cache directories; it downloads nothing into them.
    assert Path.wildcard(Path.join(cache, "**"), match_dot: true) |> Enum.all?(&File.dir?/1)
    # Recall on this tab is the full-text half: the memory is not a hit, the message is.
    view |> form("#semantic-search", query: "#near:dog my dog") |> render_submit()
    refute has_element?(view, "#semantic-hits li[id^='hit-memory-']")
    assert has_element?(view, "#semantic-hits li[id^='hit-message-']", "fts")
  end
end
