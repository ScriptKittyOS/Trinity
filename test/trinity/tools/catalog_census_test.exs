# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.CatalogCensusTest do
  @moduledoc """
  Slice 020 AC8: the effect catalog is derived from the tree, and no path other than the
  module attribute in `Trinity.Effects.Catalog` admits a `:catalog` tool.

  The population is every module loaded from this application's `.beam` files (and the
  test support ones) that implements `Trinity.Tools.Tool`: derived, not listed by hand. The
  census asserts, for each that claims `:catalog`, that the attribute names it; then plants
  the two other paths a `:catalog` tool could take (a runtime registration, a config line at
  the registry's start) and asserts each is refused and named.
  """
  use ExUnit.Case, async: false

  alias Trinity.Effects.Catalog
  alias Trinity.TestTools.{CatalogClaimer, CatalogClaimerCore}
  alias Trinity.Tools
  alias Trinity.Tools.Registry

  defp tool_modules do
    {:ok, modules} = :application.get_key(:trinity, :modules)

    # Test support modules are compiled into the same app in :test, so the list holds both.
    modules
    |> Enum.filter(&Tools.Tool.implemented_by?/1)
    |> Enum.sort()
  end

  test "the population is derived from the app's module list, not a hand list" do
    modules = tool_modules()
    assert Trinity.TestTools.Echo in modules
    assert CatalogClaimer in modules
    refute Enum.any?(modules, &(&1 == Trinity.Tools.ToolMock)), "Mox mocks are not compiled tools"
  end

  test "every :catalog tool in the tree is in the attribute, and the attribute names only :catalog tools" do
    claimers = for m <- tool_modules(), m.effect() == :catalog, do: m.name()
    # The two plants claim :catalog and are deliberately absent from the attribute: the
    # census must say so by name rather than pass on an empty catalog.
    plants = Enum.sort([CatalogClaimer.name(), CatalogClaimerCore.name()])
    assert Enum.sort(claimers) == Enum.sort(plants ++ Catalog.names())
    outside = claimers |> Enum.reject(&(&1 in Catalog.names())) |> Enum.sort()
    assert outside == plants, "a :catalog tool outside the attribute went unnamed"

    # Slice 022: the shell is the first real entry.
    assert Catalog.all() == [{"shell", :exec}]

    for {name, tier} <- Catalog.all() do
      assert tier in [:read, :write, :exec, :network, :destructive]
      assert Enum.any?(tool_modules(), &(&1.name() == name and &1.effect() == :catalog))
    end
  end

  test "path 1, a runtime registration claiming :catalog, is refused and leaves no entry" do
    assert {:error, :catalog_is_compile_time} = Tools.register(CatalogClaimer)
    # The only :catalog entries are the attribute's, all core.
    for %{effect: :catalog} = e <- Registry.list(),
        do: assert(e.kind == :core and e.name in Catalog.names())
  end

  test "path 2, a config line naming a :catalog tool absent from the attribute, refuses the registry's start" do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _}} =
             GenServer.start_link(Registry, [modules: [CatalogClaimerCore], table: :census_table],
               name: :census_registry
             )

    assert message =~ "catalog_tool_not_in_catalog"
    assert message =~ CatalogClaimerCore.name()
  end

  test "the tier map in Permissions is code: every mapped name is a core tool, or the map is empty" do
    for name <- Trinity.Permissions.mapped_names() do
      assert {:ok, %{kind: :core}} = Tools.lookup(name)
    end

    refute Enum.any?(Application.get_all_env(:trinity), fn {k, _} ->
             k in [:tiers, :tool_tiers]
           end)
  end
end
