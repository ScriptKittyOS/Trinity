# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.ThirdPartyLicenses do
  @shortdoc "Derives THIRD_PARTY_LICENSES.md from the bill of materials, or checks it"

  @moduledoc """
  The third-party licence list, derived rather than written (slice 120 AC1).

  The source is `sbom.cdx.json`, the CycloneDX bill the gate generates on every commit (slice 002),
  so this list and the bill cannot disagree: they are the same data rendered twice.

  ## The gap this closes, which the bill has and does not announce

  A Hex package carries its licences in its metadata, so the bill gets them for free. **A git
  dependency carries nothing**, and the `sbom` library emits such a component with no `licenses` key
  at all rather than with an error. Measured on this tree when the task was written: two of 132
  components, `daisyui` and `heroicons`, both `github:` dependencies, both silently unlicensed in a
  document whose purpose is to say what is in the release.

  That is the failure mode worth naming. The bill was not wrong; it was quiet, and a quiet gap in a
  supply-chain artifact is worse than a loud one because nothing downstream can tell the difference
  between "MIT" and "nobody checked".

  So a component the bill cannot supply must appear in `@declared` below, with the evidence for the
  claim, and a component in neither fails this task. There is no third option and no default: a
  licence nobody looked up is not a licence.

  ## Usage

      mix trinity.third_party_licenses                  # print
      mix trinity.third_party_licenses --check          # exit 1 if THIRD_PARTY_LICENSES.md differs
      mix trinity.third_party_licenses --write          # regenerate it
      mix trinity.third_party_licenses --bom other.json # read a different bill

  `--bom` exists so a test can hand this task a planted bill instead of writing over the real one.
  The first version of that test did write over it, which is the kind of thing that works until two
  tests run at once.

  ## The one difference `--check` accepts

  The bill lists the Erlang/OTP applications of the runtime that generates it, and the committed file
  is generated on the OTP `.tool-versions` pins. Since ADR-0014 the FIPS leg runs the container
  images' OTP (`ci/container.tool-versions`), a newer patch of the same major, so its bill carries
  newer versions of some OTP applications and nothing else changes. `--check` accepts exactly that:
  the runtime's OTP is the container's pin and not the desktop's, and the file matches the bill once
  the versions of the bill's `erlang.otp` components are read from the file. Any other difference
  still fails.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @artifact "THIRD_PARTY_LICENSES.md"
  @bom "sbom.cdx.json"

  # Components whose licence the bill cannot carry, each with the evidence for the claim. The
  # evidence is a URL at the **pinned commit**, not at a branch: a licence read from `main` is a
  # statement about today rather than about the bytes this project builds against.
  @declared %{
    "heroicons" => %{
      licence: "MIT",
      holder: "Copyright (c) Tailwind Labs, Inc.",
      evidence:
        "https://raw.githubusercontent.com/tailwindlabs/heroicons/0435d4ca364a608cc75e2f8683d374e55abbae26/LICENSE",
      why:
        "a `github:` dependency with a sparse checkout of `optimized`, so the repository's LICENSE " <>
          "is not in the tree and the lock carries no licence metadata"
    },
    "daisyui" => %{
      licence: "MIT",
      holder: "Copyright (c) 2020 Pouya Saadeghi",
      evidence:
        "https://raw.githubusercontent.com/saadeghi/daisyui/22ecff57f2c391b80a75617325748cf4d13fdf47/LICENSE",
      why:
        "a `github:` dependency with a sparse checkout of `packages/bundle`, so the repository's " <>
          "LICENSE is not in the tree and the lock carries no licence metadata"
    }
  }

  @impl Mix.Task
  def run(argv) do
    rows = rows(read_bom!(bom_path(argv)))

    case unlicensed(rows) do
      [] -> :ok
      names -> Mix.raise(unlicensed_message(names))
    end

    rendered = render(rows)

    cond do
      "--check" in argv -> check(rendered, rows)
      "--write" in argv -> write(rendered)
      true -> Mix.shell().info(rendered)
    end
  end

  @doc "Every component with its licence and where the licence came from."
  @spec rows(map()) :: [map()]
  def rows(bom) do
    bom
    |> Map.get("components", [])
    |> Enum.map(&row/1)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "The components with no licence from either source. A non-empty list is a failure."
  @spec unlicensed([map()]) :: [String.t()]
  def unlicensed(rows), do: for(r <- rows, r.licence == nil, do: r.name)

  @doc false
  @spec declared() :: map()
  def declared, do: @declared

  defp row(component) do
    name = component["name"]

    case licence_from_bom(component) do
      nil ->
        case Map.get(@declared, name) do
          nil ->
            %{name: name, version: version(component), licence: nil, source: nil, holder: nil}

          d ->
            %{
              name: name,
              version: version(component),
              licence: d.licence,
              source: :declared,
              holder: d.holder
            }
        end

      licence ->
        %{name: name, version: version(component), licence: licence, source: :bom, holder: nil}
    end
    |> Map.put(:otp?, component["group"] == "erlang.otp")
  end

  # CycloneDX puts a resolvable identifier in `license.id` and anything else in `license.name`
  # (slice 002 normalises non-SPDX strings into the second). Either is a licence; neither is not.
  defp licence_from_bom(%{"licenses" => [_ | _] = choices}) do
    choices
    |> Enum.map(fn
      %{"license" => %{"id" => id}} -> id
      %{"license" => %{"name" => name}} -> name
      %{"expression" => expression} -> expression
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ids -> Enum.join(ids, " OR ")
    end
  end

  defp licence_from_bom(_), do: nil

  # A git dependency's "version" is its commit, which is 40 characters of noise in a table. The
  # first twelve identify it and the bill carries the whole thing.
  defp version(%{"version" => v}) when is_binary(v) do
    if String.match?(v, ~r/^[0-9a-f]{40}$/), do: binary_part(v, 0, 12), else: v
  end

  defp version(_), do: ""

  defp unlicensed_message(names) do
    """
    #{length(names)} dependency has no licence in the bill of materials and no declared entry: #{Enum.join(names, ", ")}.

    A Hex package carries its licences in its metadata. A git dependency carries nothing, and the
    bill emits such a component with no licences at all rather than with an error, so a gap here is
    silent.

    Look the licence up at the **pinned commit**, not at a branch, and add it to `@declared` in
    lib/mix/tasks/trinity.third_party_licenses.ex with the URL you read it from. A licence nobody
    looked up is not a licence, and this task has no default for one.
    """
  end

  @doc "The file `rows` render to: what `--write` writes and `--check` compares."
  @spec render([map()]) :: String.t()
  def render(rows) do
    declared = Enum.filter(rows, &(&1.source == :declared))

    """
    <!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
    <!-- SPDX-License-Identifier: Apache-2.0 -->
    <!-- Generated by `mix trinity.third_party_licenses --write` from sbom.cdx.json. Do not edit by
         hand: the gate regenerates it and fails when this file and the bill disagree. -->
    # Third-party licences

    #{length(rows)} components, derived from `sbom.cdx.json`, the CycloneDX bill this project's
    quality gate generates on every commit. This file and that bill are the same data rendered
    twice, so they cannot disagree.

    Trinity itself is Apache-2.0 (`LICENSE`). Everything below is somebody else's work.

    **What this list covers.** Every component of the bill, which is every dependency the lock file
    resolves, including the ones that exist only to build and test this project and ship in no
    artifact. That is deliberate: a list of only the shipped subset would be the more flattering
    document and the less useful one, because a licence obligation can attach to a build-time
    dependency too. Which environment each one belongs to is in `mix.exs`; this file does not repeat
    it, and a reader should not infer from an entry here that the component is in a release.

    | Component | Version | Licence | Source of the licence |
    |---|---|---|---|
    #{Enum.map_join(rows, "\n", &line/1)}

    ## Where a licence came from

    **`bill`** means the licence is in the dependency's own package metadata and the bill carries it.

    **`declared`** means the bill could not supply one and it was looked up by hand. A Hex package
    carries its licences in its metadata; a git dependency carries nothing, and the bill emits such
    a component with no licence at all rather than with an error. That gap is silent, so this
    project fills it explicitly rather than letting the absence pass: `mix
    trinity.third_party_licenses` fails on a component with neither, and the gate runs it.

    #{declared_notes(declared)}
    """
  end

  defp declared_notes([]), do: "No component currently needs a declared licence."

  defp declared_notes(rows) do
    """
    The #{length(rows)} declared #{if length(rows) == 1, do: "entry", else: "entries"}, with the evidence:

    #{Enum.map_join(rows, "\n\n", &declared_note/1)}
    """
  end

  defp declared_note(%{name: name, holder: holder}) do
    d = Map.fetch!(@declared, name)

    "- **#{name}**: #{d.licence}, `#{holder}`. Read at the pinned commit: <#{d.evidence}>. " <>
      "Needed because it is #{d.why}."
  end

  defp line(r) do
    "| `#{r.name}` | `#{r.version}` | #{r.licence} | #{r.source} |"
  end

  defp bom_path(argv) do
    case Enum.find_index(argv, &(&1 == "--bom")) do
      nil -> @bom
      i -> Enum.at(argv, i + 1) || @bom
    end
  end

  defp read_bom!(path) do
    case File.read(path) do
      {:ok, json} ->
        Jason.decode!(json)

      {:error, :enoent} ->
        Mix.raise(
          "#{@bom} is missing. Run `mix trinity.sbom` first; the gate runs it before this."
        )
    end
  end

  @doc """
  `{:ok, names}` when `committed` differs from what `rows` render only in the versions of OTP
  applications, and `pins` (`{runtime, desktop, container}` OTP versions) says the runtime is the
  container's pin and not the desktop's; `names` are the applications whose version differs.
  `:error` otherwise.
  """
  @spec otp_drift(String.t(), [map()], {String.t() | nil, String.t() | nil, String.t() | nil}) ::
          {:ok, [String.t()]} | :error
  def otp_drift(committed, rows, pins) do
    versions =
      for [_, name, version] <- Regex.scan(~r/^\| `([^`]+)` \| `([^`]*)` \|/m, committed),
          into: %{},
          do: {name, version}

    as_committed = Enum.map(rows, &committed_version(&1, versions))
    drifted = for r <- rows, r.otp?, versions[r.name] != r.version, do: r.name

    if container_runtime?(pins) and Enum.all?(as_committed, & &1.version) and
         render(as_committed) == committed,
       do: {:ok, drifted},
       else: :error
  end

  defp committed_version(%{otp?: true} = row, versions),
    do: %{row | version: Map.get(versions, row.name)}

  defp committed_version(row, _versions), do: row

  defp container_runtime?({runtime, desktop, container}),
    do: runtime != nil and runtime == container and runtime != desktop

  # The running OTP (an OTP install carries `releases/<major>/OTP_VERSION`; the gate never runs in
  # a release) and the two pins.
  defp pins do
    runtime =
      case File.read(
             Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"])
           ) do
        {:ok, text} -> String.trim(text)
        {:error, _} -> nil
      end

    {runtime, erlang_pin(".tool-versions"), erlang_pin("ci/container.tool-versions")}
  end

  defp erlang_pin(path) do
    with {:ok, text} <- File.read(path),
         [_, version] <- Regex.run(~r/^erlang\s+(\S+)\s*$/m, text) do
      version
    else
      _ -> nil
    end
  end

  defp write(rendered) do
    File.write!(@artifact, rendered)
    Mix.shell().info("trinity.third_party_licenses: wrote #{@artifact}")
  end

  defp check(rendered, rows) do
    case File.read(@artifact) do
      {:ok, ^rendered} ->
        Mix.shell().info("trinity.third_party_licenses: OK. #{@artifact} matches the bill")

      {:ok, committed} ->
        case otp_drift(committed, rows, pins()) do
          {:ok, names} ->
            Mix.shell().info(
              "trinity.third_party_licenses: OK. #{@artifact} matches the bill apart from the " <>
                "versions of #{length(names)} OTP application(s) (#{Enum.join(names, ", ")}): " <>
                "this runtime is the container images' OTP, the file is the desktop pin's (ADR-0014)"
            )

          :error ->
            Mix.raise(
              "#{@artifact} does not match the bill of materials. Run " <>
                "`mix trinity.third_party_licenses --write` and commit the result."
            )
        end

      {:error, :enoent} ->
        Mix.raise("#{@artifact} is missing. Run `mix trinity.third_party_licenses --write`.")
    end
  end
end
