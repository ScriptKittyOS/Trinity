# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.Findings do
  @shortdoc "Gates a vulnerability scan of the headless image on its justifications (AC3, AC4)"

  @moduledoc """
  Reads a grype JSON report of the headless image and the justification file, and fails on a
  High or Critical finding with no justification row (slice 130, AC3) or on a row whose finding
  no longer appears in the scan (AC4). `docs/regulated/headless-image.md` describes the scan.

      mix trinity.image.findings --scan grype.json [--justifications PATH] [--out findings.csv]

  A finding is keyed the way Iron Bank's Vulnerability Assessment Tracker keys one: the
  identifier, the package as `name-version`, and the package path, which is empty for a package
  the OS package database reports (their `pkgdb`). So a justification is for one version of one
  package: upgrading the package retires the row, and the staleness check says so rather than
  letting the file keep an excuse for something that changed.

  Only High and Critical gate. Everything else is counted and written to `--out`, which is the
  shape a submission's findings take: one row per finding with its justification, if any.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @justifications "ci/headless/justifications.yaml"
  @gated ~w(critical high)
  @row_keys ~w(finding package packagePath severity scanSource justification)

  @typedoc "One finding, keyed by `{finding, package, packagePath}`."
  @type finding :: %{
          finding: String.t(),
          package: String.t(),
          packagePath: String.t() | nil,
          severity: String.t(),
          scanSource: String.t(),
          fix: String.t()
        }

  @typedoc "The outcome of comparing a scan with the justification rows."
  @type evaluation :: %{
          findings: [finding()],
          unjustified: [finding()],
          stale: [map()],
          invalid: [String.t()],
          justified: [{finding(), map()}]
        }

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [scan: :string, justifications: :string, out: :string])

    scan = opts[:scan] || Mix.raise("usage: mix trinity.image.findings --scan grype.json")
    path = opts[:justifications] || @justifications
    report = scan |> File.read!() |> Jason.decode!()
    evaluation = evaluate(findings(report), read_rows(path))

    if out = opts[:out], do: File.write!(out, to_csv(evaluation))

    counts =
      evaluation.findings
      |> Enum.frequencies_by(& &1.severity)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {s, n} -> "#{n} #{s}" end)

    Mix.shell().info(
      "trinity.image.findings: #{length(evaluation.findings)} finding(s): #{counts}"
    )

    Mix.shell().info("trinity.image.findings: #{length(evaluation.justified)} justified")

    case violations(evaluation, path) do
      [] ->
        Mix.shell().info("trinity.image.findings: OK")

      found ->
        Enum.each(found, &Mix.shell().error("FAIL #{&1}"))
        Mix.raise("trinity.image.findings: #{length(found)} violation(s)")
    end
  end

  @doc "The findings in a grype JSON report, one per key, severities lower-cased."
  @spec findings(map()) :: [finding()]
  def findings(report) do
    report
    |> Map.get("matches", [])
    |> Enum.map(&to_finding/1)
    |> Enum.uniq_by(&key/1)
    |> Enum.sort_by(&{severity_rank(&1.severity), &1.finding, &1.package})
  end

  defp to_finding(match) do
    artifact = match["artifact"] || %{}
    vulnerability = match["vulnerability"] || %{}
    fix = vulnerability["fix"] || %{}

    %{
      finding: vulnerability["id"],
      package: "#{artifact["name"]}-#{artifact["version"]}",
      packagePath: package_path(artifact),
      severity: String.downcase(vulnerability["severity"] || "unknown"),
      scanSource: "grype",
      fix: Enum.join([fix["state"] | List.wrap(fix["versions"])] |> Enum.reject(&is_nil/1), " ")
    }
  end

  # A package the OS package database reports has no path in Iron Bank's key (their `pkgdb`).
  defp package_path(%{"type" => type}) when type in ["rpm", "deb", "apk"], do: nil

  defp package_path(artifact) do
    case artifact["locations"] do
      [%{"path" => path} | _] -> path
      _ -> nil
    end
  end

  @doc """
  Compares `findings` with justification `rows`: which gated findings have no row (AC3), which
  rows match no finding (AC4), and which rows are malformed.
  """
  @spec evaluate([finding()], [map()]) :: evaluation()
  def evaluate(findings, rows) do
    by_key = Map.new(findings, &{key(&1), &1})
    {valid, invalid} = Enum.split_with(rows, &(row_problems(&1) == []))
    rows_by_key = Map.new(valid, &{row_key(&1), &1})

    %{
      findings: findings,
      unjustified:
        Enum.filter(findings, &(&1.severity in @gated and not Map.has_key?(rows_by_key, key(&1)))),
      stale: Enum.reject(valid, &Map.has_key?(by_key, row_key(&1))),
      invalid:
        for(
          row <- invalid,
          problem <- row_problems(row),
          do: "#{inspect(row_key(row))}: #{problem}"
        ),
      justified: for(f <- findings, row = rows_by_key[key(f)], row != nil, do: {f, row})
    }
  end

  @doc "One line per violation in `evaluation`, each naming its criterion; empty when it passes."
  @spec violations(evaluation(), Path.t()) :: [String.t()]
  def violations(evaluation, path \\ @justifications) do
    unjustified =
      for f <- evaluation.unjustified do
        "AC3: #{f.finding} (#{f.severity}) in #{f.package} at #{f.packagePath || "pkgdb"} " <>
          "has no justification row in #{path}" <> fixed_in(f.fix)
      end

    stale =
      for row <- evaluation.stale do
        "AC4: #{path} justifies #{row["finding"]} in #{row["package"]} at " <>
          "#{row["packagePath"] || "pkgdb"}, which the scan no longer reports; remove the row"
      end

    invalid = for line <- evaluation.invalid, do: "AC3: malformed justification row #{line}"
    unjustified ++ stale ++ invalid
  end

  defp fixed_in(""), do: ""
  defp fixed_in(fix), do: " (fix: #{fix})"

  defp row_problems(row) when is_map(row) do
    missing = for k <- @row_keys, not Map.has_key?(row, k), do: "lacks #{k}"

    empty =
      if is_binary(row["justification"]) and String.trim(row["justification"]) != "",
        do: [],
        else: ["has no justification text"]

    if missing == [], do: empty, else: missing
  end

  defp row_problems(_), do: ["is not a mapping"]

  defp key(f), do: {f.finding, f.package, f.packagePath}
  defp row_key(row) when is_map(row), do: {row["finding"], row["package"], row["packagePath"]}
  defp row_key(row), do: row

  defp severity_rank(severity) do
    Enum.find_index(~w(critical high medium low negligible unknown), &(&1 == severity)) || 6
  end

  @doc "The findings as CSV in the Vulnerability Assessment Tracker's field order, justified or not."
  @spec to_csv(evaluation()) :: String.t()
  def to_csv(evaluation) do
    rows = Map.new(evaluation.justified, fn {f, row} -> {key(f), row["justification"]} end)
    header = "finding,severity,scanSource,package,packagePath,fix,justification"

    lines =
      for f <- evaluation.findings do
        [
          f.finding,
          f.severity,
          f.scanSource,
          f.package,
          f.packagePath || "",
          f.fix,
          rows[key(f)] || ""
        ]
        |> Enum.map_join(",", &csv_field/1)
      end

    Enum.join([header | lines], "\n") <> "\n"
  end

  defp csv_field(value) do
    text = to_string(value)

    if String.contains?(text, [",", "\"", "\n"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  defp read_rows(path) do
    {:ok, data} = YamlElixir.read_from_file(path)
    (data || %{}) |> Map.get("justifications", []) |> List.wrap()
  end
end
