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
    # `--bom` rather than writing over the real bill. The first version of this test did write over
    # it, which coupled the test to `mix trinity.sbom` having already run: the postgres leg runs
    # `mix test` without `mix gate`, so there is no bill there and the test failed on a missing
    # file rather than on anything it was written to check. It also wrote to the repository root
    # from inside a test, which works right up until two tests run at once.
    path = Path.join(System.tmp_dir!(), "planted-#{System.unique_integer([:positive])}.cdx.json")
    File.write!(path, Jason.encode!(bom([git_component("planted_dependency")])))
    on_exit(fn -> File.rm(path) end)

    message = assert_raise(Mix.Error, fn -> Task.run(["--bom", path]) end) |> Map.fetch!(:message)

    assert message =~ "planted_dependency"
    assert message =~ "pinned commit"
    assert message =~ "is not a licence"
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

  test "the committed list has a licence in every row" do
    # Reads the committed artifact, not the generated bill. The bill is gitignored and produced by
    # `mix trinity.sbom` during `mix gate`, so a test that reads it passes or fails depending on
    # which CI leg runs it: the postgres leg runs `mix test` without `mix gate` and has no bill.
    # What this criterion is about is the file in the tree.
    rows =
      Path.expand("../../THIRD_PARTY_LICENSES.md", __DIR__)
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))

    assert length(rows) > 100, "only #{length(rows)} rows: the list looks truncated"

    for row <- rows do
      [_, _name, _version, licence, source, _] = String.split(row, "|")
      assert String.trim(licence) != "", "a row carries no licence: #{row}"

      assert String.trim(source) in ["bom", "declared"],
             "a row's licence came from nowhere nameable: #{row}"
    end
  end
end
