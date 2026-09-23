# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Sbom do
  @shortdoc "Generates the CycloneDX software bill of materials, and says what it is blind to"
  @moduledoc """
  Slice 002. Runs `mix sbom.cyclonedx` over `mix.lock` and writes `sbom.cdx.json`, then makes two
  corrections to what it generated. Neither is decoration: without the first the bill is read as
  saying more than it knows, and without the second it is not a valid CycloneDX document at all.

  **What the bill covers, and what it does not.** It is generated from `mix.lock`, so it is exact
  for Hex dependencies and blind to the Rust crates the desktop shell links. A reader who takes it
  for the whole picture would conclude the product has no Rust in it, which is false. Rather than
  leave that to a paragraph in a document nobody reads beside the file, the coverage is written
  into the bill itself as a `metadata.properties` entry, where a tool or a person reading the
  artifact alone will find it.

  **Licence identifiers that SPDX does not define.** CycloneDX validates `license.id` against the
  SPDX enumeration and rejects a bill carrying anything else, while a Hex package's `licenses`
  metadata is free text that its author typed. `sbom` emits a lone licence string as an `id`
  without checking it (`deps/sbom/lib/sbom/cyclonedx.ex`, `license: {:id, license}`), so one
  dependency writing `BSD 2-Clause` for `BSD-2-Clause` makes the whole document fail validation:
  measured, not supposed, on the first bill this project generated. Any identifier this project
  cannot find in the vendored SPDX list is therefore moved to `license.name`, which is where
  CycloneDX puts a licence it cannot resolve to an identifier. Nothing is dropped and nothing is
  guessed: `BSD 2-Clause` stays `BSD 2-Clause`, recorded as a name rather than asserted as an
  identifier it is not.

  The gate runs this, so a bill that cannot be generated fails the build rather than being missing
  from a release nobody checked.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @output "sbom.cdx.json"
  @spdx_ids_path "priv/spdx/license-ids.txt"
  @coverage_property "trinity:coverage"
  @coverage_value "Hex dependencies resolved from mix.lock. This bill does NOT cover the Rust " <>
                    "crates linked by the desktop shell (src-tauri/Cargo.lock); that half is " <>
                    "slice 121. Absence of a component here is not evidence of its absence " <>
                    "from the product."

  @impl Mix.Task
  def run(argv) do
    output = Enum.at(argv, 0, @output)
    Mix.Task.run("sbom.cyclonedx", ["--force", "--pretty", "--output", output])
    annotate!(output)
    Mix.shell().info("trinity.sbom: #{output} written and annotated with its coverage")
  end

  @doc """
  The SPDX licence identifiers CycloneDX accepts, as a set.

  Read from the vendored list rather than from a dependency: see the file's own header for where
  it came from and for which way it fails when it goes stale.
  """
  @spec spdx_ids() :: MapSet.t(String.t())
  def spdx_ids do
    Application.app_dir(:trinity, @spdx_ids_path)
    |> then(fn path -> if File.exists?(path), do: path, else: @spdx_ids_path end)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> MapSet.new()
  end

  @doc "The property name the bill carries its coverage statement under."
  @spec coverage_property() :: String.t()
  def coverage_property, do: @coverage_property

  @doc "The coverage statement written into the bill."
  @spec coverage_value() :: String.t()
  def coverage_value, do: @coverage_value

  # Read, add the property, write back. A generation that produced something unreadable fails
  # here rather than shipping: the point of the bill is that it can be read.
  defp annotate!(output) do
    bom =
      case output |> File.read!() |> Jason.decode() do
        {:ok, %{"bomFormat" => "CycloneDX"} = bom} ->
          bom

        {:ok, other} ->
          Mix.raise("#{output} is not a CycloneDX document: #{inspect(Map.keys(other))}")

        {:error, reason} ->
          Mix.raise("#{output} is not readable as JSON: #{inspect(reason)}")
      end

    metadata = Map.get(bom, "metadata", %{})

    properties =
      metadata
      |> Map.get("properties", [])
      |> Enum.reject(&(Map.get(&1, "name") == @coverage_property))
      |> Kernel.++([%{"name" => @coverage_property, "value" => @coverage_value}])

    annotated =
      bom
      |> Map.put("metadata", Map.put(metadata, "properties", properties))
      |> Map.replace_lazy("components", &normalise_licenses(&1, spdx_ids()))

    File.write!(output, Jason.encode_to_iodata!(annotated, pretty: true))
  end

  # An identifier SPDX does not define is not an identifier. It keeps its text and changes field.
  defp normalise_licenses(components, ids) when is_list(components) do
    Enum.map(components, fn component ->
      Map.replace_lazy(component, "licenses", fn choices ->
        Enum.map(choices, &normalise_choice(&1, ids))
      end)
    end)
  end

  defp normalise_licenses(components, _ids), do: components

  defp normalise_choice(%{"license" => %{"id" => id} = license} = choice, ids) do
    if MapSet.member?(ids, id) do
      choice
    else
      %{choice | "license" => license |> Map.delete("id") |> Map.put("name", id)}
    end
  end

  defp normalise_choice(choice, _ids), do: choice
end
