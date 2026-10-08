# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.ProvenanceTest do
  @moduledoc """
  Slice 131, AC2, the producer's half: the provenance names the builder, the repository and the
  commit, lists the build's other inputs by digest, and is refused for an image that does not
  name the same commit. The consumer's half, a provenance whose commit does not match the image,
  is the verification sequence's (`test/image_supply_chain_test.exs`).
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Image.Provenance

  @commit String.duplicate("a1", 20)
  @other "0123456789abcdef0123456789abcdef01234567"
  @repo "https://github.com/ScriptKittyOS/Trinity"
  @builder "https://github.com/ScriptKittyOS/Trinity/.github/workflows/headless-image.yml@refs/heads/main"

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        commit: @commit,
        repository: @repo,
        builder_id: @builder,
        ref: "refs/heads/main",
        invocation: "https://github.com/ScriptKittyOS/Trinity/actions/runs/1/attempts/1",
        revision_label: @commit
      },
      overrides
    )
  end

  defp tree_predicate do
    Provenance.predicate(
      params(),
      Provenance.read_resources!("ci/ironbank/hardening_manifest.yaml"),
      Provenance.read_bases!("ci/headless/bases.env")
    )
  end

  describe "the predicate" do
    test "names the builder, the source repository and the exact source commit" do
      p = tree_predicate()

      assert p["runDetails"]["builder"]["id"] == @builder
      assert p["buildDefinition"]["externalParameters"]["repository"] == @repo
      assert p["buildDefinition"]["buildType"] == Provenance.build_type()

      [source | _] = p["buildDefinition"]["resolvedDependencies"]

      assert source == %{
               "uri" => "git+#{@repo}@refs/heads/main",
               "digest" => %{"gitCommit" => @commit}
             }

      assert p["runDetails"]["metadata"]["invocationId"] =~ "/actions/runs/1/"
    end

    test "lists every resource of the hardening manifest, with its digest" do
      resources = Provenance.read_resources!("ci/ironbank/hardening_manifest.yaml")
      deps = tree_predicate()["buildDefinition"]["resolvedDependencies"]

      assert resources != []

      for r <- resources do
        assert %{
                 "name" => r["filename"],
                 "uri" => r["url"],
                 "digest" => %{r["validation"]["type"] => r["validation"]["value"]}
               } in deps
      end
    end

    test "lists both bases by the digest bases.env pins" do
      deps = tree_predicate()["buildDefinition"]["resolvedDependencies"]
      bases = Enum.filter(deps, &String.starts_with?(&1["uri"], "oci://"))

      assert Enum.map(bases, & &1["uri"]) == [
               "oci://registry.access.redhat.com/ubi9/ubi-micro",
               "oci://registry.access.redhat.com/ubi9"
             ]

      env = File.read!("ci/headless/bases.env")

      for %{"digest" => %{"sha256" => hex}} <- bases do
        assert env =~ "@sha256:" <> hex
      end
    end
  end

  describe "AC2: provenance is refused" do
    test "for an image that names no commit (built from a modified tree)" do
      for label <- [nil, ""] do
        assert [msg] = Provenance.refusals(params(%{revision_label: label}))
        assert msg =~ "names no commit in its org.opencontainers.image.revision label"
      end
    end

    test "for an image whose label is its base's (UBI9 micro names Red Hat's commit)" do
      redhat = "b3f01943b83e7975e01233fc613cb5f0941b57d1"
      assert [msg] = Provenance.refusals(params(%{revision_label: redhat}))
      assert msg =~ ~s(is "#{redhat}", not --commit)
    end

    test "for an image that names another commit" do
      assert [msg] = Provenance.refusals(params(%{revision_label: @other}))
      assert msg =~ ~s(is "#{@other}", not --commit #{@commit})
    end

    test "for an abbreviated commit, or no repository or builder" do
      assert [msg] = Provenance.refusals(params(%{commit: "a1a1a1a", revision_label: "a1a1a1a"}))
      assert msg =~ "is not a full 40-character"

      found = Provenance.refusals(params(%{repository: nil, builder_id: ""}))
      assert "--repository is required" in found
      assert "--builder-id is required" in found
    end

    test "and accepted when the image names the commit" do
      assert Provenance.refusals(params()) == []
    end
  end

  test "the task refuses without its arguments" do
    assert_raise Mix.Error, ~r/usage: mix trinity.image.provenance/, fn ->
      Provenance.run(["--commit", @commit])
    end
  end
end
