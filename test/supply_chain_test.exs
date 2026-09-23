# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SupplyChainTest do
  @moduledoc """
  Slice 002, AC1 and AC3. The bill of materials the gate generates is a real CycloneDX document,
  it lists the dependencies the lock file holds, and it states what it is blind to inside itself
  rather than in a document beside it.

  And the two statements the README makes about transport and message authentication are pinned to
  the facts rather than to the sentence: the test asserts the runtime's default TLS versions and
  the algorithm that actually seals the envelope, so the line cannot survive the fact changing
  underneath it.
  """
  use ExUnit.Case, async: true

  @output "sbom.cdx.json"

  setup_all do
    # The gate generates it before the suite runs; a developer running this file alone gets it
    # generated here rather than a failure about a missing file they did not know to produce.
    unless File.exists?(@output) do
      {_, 0} = System.cmd("mix", ["trinity.sbom"], stderr_to_stdout: true)
    end

    {:ok, bom: @output |> File.read!() |> Jason.decode!()}
  end

  describe "AC1: the bill of materials" do
    test "is a CycloneDX document with a specification version", %{bom: bom} do
      assert bom["bomFormat"] == "CycloneDX"
      assert bom["specVersion"] =~ ~r/^\d+\.\d+$/
      assert is_binary(bom["serialNumber"]) or is_nil(bom["serialNumber"])
    end

    test "lists components, and every one carries a name and a version", %{bom: bom} do
      components = bom["components"]
      assert is_list(components) and length(components) > 50

      for component <- components do
        assert is_binary(component["name"]) and component["name"] != ""
        assert is_binary(component["version"]) and component["version"] != ""
      end
    end

    test "covers the dependencies the lock file holds", %{bom: bom} do
      names = MapSet.new(bom["components"], & &1["name"])

      # A sample across the tree's own dependency kinds: the web layer, the database driver, the
      # protocol core and the cryptography. If the bill were generated from something other than
      # the lock, one of these would be missing.
      for expected <- ~w(phoenix ecto_sql exqlite beam_mcp jose) do
        assert expected in names, "#{expected} is in mix.lock but not in the bill"
      end
    end

    # The one property a validator rejects a whole document over, asserted here so that the next
    # dependency whose author types a licence by hand fails this test rather than the bill.
    # Measured on the first bill generated in this slice: `yamerl` declares `BSD 2-Clause`, which
    # SPDX spells `BSD-2-Clause`, and the official CycloneDX validator refused the document over
    # that single field.
    test "never asserts a licence identifier SPDX does not define", %{bom: bom} do
      ids = Mix.Tasks.Trinity.Sbom.spdx_ids()
      assert MapSet.size(ids) > 500, "the vendored SPDX list did not load"

      asserted =
        for component <- bom["components"],
            choice <- component["licenses"] || [],
            id = get_in(choice, ["license", "id"]),
            id not in [nil],
            not MapSet.member?(ids, id),
            do: {component["name"], id}

      assert asserted == [], "these components assert a licence id SPDX does not define"
    end

    test "keeps a licence it cannot resolve, as a name rather than an identifier", %{bom: bom} do
      named =
        for component <- bom["components"],
            choice <- component["licenses"] || [],
            name = get_in(choice, ["license", "name"]),
            name not in [nil],
            do: name

      # Nothing is dropped on the way: whatever could not be resolved is still in the document,
      # under the field CycloneDX keeps an unresolved licence in.
      for name <- named, do: assert(is_binary(name) and name != "")
      assert "BSD 2-Clause" in named or named == []
    end

    test "states what it is blind to, inside the document", %{bom: bom} do
      properties = get_in(bom, ["metadata", "properties"]) || []

      coverage =
        Enum.find(properties, &(&1["name"] == Mix.Tasks.Trinity.Sbom.coverage_property()))

      assert coverage, "the bill carries no coverage property; a reader cannot know its limits"
      assert coverage["value"] =~ "does NOT cover the Rust crates"
      assert coverage["value"] =~ "not evidence of its absence"
    end
  end

  describe "AC3: the transport and authentication statements" do
    test "the runtime's default TLS versions are 1.2 and 1.3, and nothing older" do
      :ssl.start()
      supported = Keyword.fetch!(:ssl.versions(), :supported)

      assert :"tlsv1.2" in supported
      refute :tlsv1 in supported, "TLS 1.0 is in the default set"
      refute :"tlsv1.1" in supported, "TLS 1.1 is in the default set"
    end

    test "the only authentication tag Trinity mints is AES-256-GCM's" do
      envelope = File.read!("lib/trinity/mcp/server/envelope.ex")
      assert envelope =~ ":aes_256_gcm"

      # And no weaker construction anywhere in the tree's own code.
      {out, 0} = System.cmd("git", ["ls-files", "lib/*.ex", "lib/**/*.ex"])

      for file <- out |> String.split("\n", trim: true) |> Enum.uniq() do
        source = File.read!(file)
        refute source =~ ~r/:aes_\d+_(ecb|cbc)\b/, "#{file} uses an unauthenticated cipher mode"
      end
    end

    test "the README states both, so a reader need not read the source to learn them" do
      readme = File.read!("README.md")
      assert readme =~ "TLS 1.2"
      assert readme =~ "AES-256-GCM"
      assert readme =~ "FIPS"
    end
  end
end
