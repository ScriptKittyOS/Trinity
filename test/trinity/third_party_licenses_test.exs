# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule ThirdPartyLicensesTest do
  @moduledoc """
  Slice 120 AC1: the derived third-party licence list is complete, and a dependency without a
  licence entry makes the check fail.

  The second half is the one that matters. A list that happens to be complete today proves nothing
  about the next dependency someone adds, and the way this fails in practice is silent: a Hex
  package carries its licences in its metadata, a git dependency carries nothing, and the bill of
  materials emits such a component with no `licenses` key rather than with an error. Two of this
  tree's 132 components were in exactly that state when the task was written.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.ThirdPartyLicenses, as: Task

  defp bom(components), do: %{"components" => components}

  defp hex_component(name, licence) do
    %{"name" => name, "version" => "1.0.0", "licenses" => [%{"license" => %{"id" => licence}}]}
  end

  defp git_component(name) do
    %{"name" => name, "version" => String.duplicate("a", 40)}
  end

  test "a component whose package metadata carries a licence is read from the bill" do
    [row] = Task.rows(bom([hex_component("jason", "Apache-2.0")]))
    assert %{name: "jason", licence: "Apache-2.0", source: :bom} = row
  end

  test "a component with no licence and no declared entry is unlicensed, which is a failure" do
    rows = Task.rows(bom([git_component("planted_dependency")]))

    assert ["planted_dependency"] = Task.unlicensed(rows),
           "a dependency with no licence anywhere passed the check. The bill emits a git " <>
             "dependency with no licences at all rather than with an error, so this gap is " <>
             "silent and nothing downstream can tell it from a real answer"
  end

  test "the task raises on it, naming the dependency and what to do" do
    File.cd!(Path.expand("../..", __DIR__), fn ->
      original = File.read!("sbom.cdx.json")

      try do
        File.write!("sbom.cdx.json", Jason.encode!(bom([git_component("planted_dependency")])))

        message =
          assert_raise(Mix.Error, fn -> Task.run([]) end) |> Map.fetch!(:message)

        assert message =~ "planted_dependency"
        assert message =~ "pinned commit"
        assert message =~ "is not a licence"
      after
        File.write!("sbom.cdx.json", original)
      end
    end)
  end

  test "a declared entry fills the gap the bill leaves, and says it was declared" do
    [name | _] = Map.keys(Task.declared())
    [row] = Task.rows(bom([git_component(name)]))

    assert %{source: :declared} = row
    assert row.licence
    assert row.holder
  end

  test "every declared entry carries evidence at a pinned commit, not at a branch" do
    for {name, d} <- Task.declared() do
      assert d.evidence =~ ~r|/[0-9a-f]{40}/|,
             "#{name}'s evidence URL is not at a pinned commit: #{d.evidence}. A licence read " <>
               "from a branch is a statement about today, not about the bytes this project builds " <>
               "against"

      assert is_binary(d.holder) and d.holder != ""
      assert is_binary(d.why) and d.why != ""
    end
  end

  test "the committed list has no unlicensed component" do
    bom =
      "sbom.cdx.json"
      |> Path.expand(Path.expand("../..", __DIR__))
      |> File.read!()
      |> Jason.decode!()

    assert [] == bom |> Task.rows() |> Task.unlicensed()
  end
end
