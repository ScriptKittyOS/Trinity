# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.SessionSearchTest do
  @moduledoc "Slice 031 AC4's automatic half: the tool through the runner in force, at most limit hits, snippets, a read's receipts."
  use Trinity.DataCase, async: false

  alias Trinity.{Effects, Factory, Receipts, Sessions}
  alias Trinity.Tools.Context

  setup do
    old = Factory.session!(%{title: "Last week's planning"})

    for i <- 1..5,
        do:
          {:ok, _} =
            Sessions.append_message(old.id, %{
              role: "user",
              content: "we decided to ship the #{i}th widget on friday"
            })

    {:ok, _} =
      Sessions.append_message(old.id, %{role: "assistant", content: "noted: friday it is"})

    here = Factory.session!(%{title: "Now"})
    scope = Receipts.session_scope(here.id)
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, here: here, old: old, scope: scope}
  end

  test "registered as a core read tool with the catalog untouched" do
    assert {:ok, %{kind: :core, risk: :read, effect: :none}} =
             Trinity.Tools.lookup("session_search")

    assert Trinity.Permissions.tier("session_search") == :read
    refute "session_search" in Trinity.Tools.Catalog.names()
  end

  test "returns at most limit hits with snippets, names the session, and runs as a read with a query receipt",
       %{here: here, old: old, scope: scope} do
    ctx = %Context{session_id: here.id, caller: here.id}
    call = %{id: "c1", name: "session_search", args: %{"query" => "decided friday", "limit" => 3}}
    assert {:ok, %{content: text, meta: meta}, _} = Effects.Runner.run(call, ctx)
    lines = String.split(text, "\n")
    assert length(lines) == 3
    assert Enum.all?(lines, &(&1 =~ "Last week's planning (#{old.id})" and &1 =~ "[friday]"))
    assert meta["hits"] == 3 and meta["limit"] == 3
    assert Enum.map(Receipts.list(scope), & &1.kind) == ["decision", "query"]

    assert {:ok, %{content: "No message matches \"zzz\"."}, _} =
             Effects.Runner.run(
               %{id: "c2", name: "session_search", args: %{"query" => "zzz"}},
               ctx
             )

    assert {:error, {:invalid_args, _}, _} =
             Effects.Runner.run(
               %{id: "c3", name: "session_search", args: %{"query" => "x", "limit" => 500}},
               ctx
             )
  end
end
