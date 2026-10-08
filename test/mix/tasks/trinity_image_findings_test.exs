# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.FindingsTest do
  @moduledoc """
  Slice 130, AC3 and AC4: the scan gate fails on a High or Critical finding with no justification
  row, passes once the row exists, and fails on a row whose finding the scan no longer reports.
  The reports are grype's JSON shape, cut down to the fields the gate reads; the live run on the
  built image is in the slice's PROOF.md.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Image.Findings

  defp rpm(id, severity, name, version, state \\ "not-fixed") do
    %{
      "vulnerability" => %{
        "id" => id,
        "severity" => severity,
        "fix" => %{"state" => state, "versions" => []}
      },
      "artifact" => %{
        "name" => name,
        "version" => version,
        "type" => "rpm",
        "locations" => [%{"path" => "/var/lib/rpm/rpmdb.sqlite"}]
      }
    }
  end

  defp binary(id, severity, fixed) do
    %{
      "vulnerability" => %{
        "id" => id,
        "severity" => severity,
        "fix" => %{"state" => "fixed", "versions" => fixed}
      },
      "artifact" => %{
        "name" => "erlang",
        "version" => "28.5.0.5",
        "type" => "binary",
        "locations" => [%{"path" => "/opt/trinity/erts-16.4.0.5/bin/beam.smp"}]
      }
    }
  end

  defp row(finding, package, path \\ nil) do
    %{
      "finding" => finding,
      "package" => package,
      "packagePath" => path,
      "severity" => "high",
      "scanSource" => "grype",
      "justification" => "Inherited from the base; the vendor lists no fix."
    }
  end

  defp gate(matches, rows),
    do:
      %{"matches" => matches}
      |> Findings.findings()
      |> Findings.evaluate(rows)
      |> Findings.violations()

  test "an OS package finding is keyed with no path, a binary's by its path" do
    [os, bin] =
      Findings.findings(%{
        "matches" => [
          rpm("CVE-1", "High", "pcre2", "10.40-6.el9"),
          binary("CVE-2", "Low", ["28.5.0.7"])
        ]
      })

    assert {os.finding, os.package, os.packagePath} == {"CVE-1", "pcre2-10.40-6.el9", nil}

    assert {bin.package, bin.packagePath} ==
             {"erlang-28.5.0.5", "/opt/trinity/erts-16.4.0.5/bin/beam.smp"}
  end

  test "AC3: a planted High finding with no row fails, and passes once justified" do
    planted = rpm("CVE-2099-0001", "High", "openssl-libs", "1:3.5.8-1.el9_8")

    assert [violation] = gate([planted], [])

    assert violation =~
             ~r/^AC3: CVE-2099-0001 \(high\) in openssl-libs-1:3\.5\.8-1\.el9_8 at pkgdb has no justification row/

    assert gate([planted], [row("CVE-2099-0001", "openssl-libs-1:3.5.8-1.el9_8")]) == []
  end

  test "AC3: a Critical finding with a fix available says what fixes it" do
    assert [violation] = gate([binary("CVE-2099-0002", "Critical", ["28.5.0.7"])], [])
    assert violation =~ "(critical) in erlang-28.5.0.5 at /opt/trinity/erts-16.4.0.5/bin/beam.smp"
    assert violation =~ "(fix: fixed 28.5.0.7)"
  end

  test "AC3: Medium and below are reported, not gated" do
    assert gate(
             [
               rpm("CVE-2099-0003", "Medium", "zlib", "1.2.11"),
               rpm("CVE-2099-0004", "Negligible", "zlib", "1.2.11")
             ],
             []
           ) == []
  end

  test "AC4: a planted row whose finding the scan no longer reports fails as stale" do
    current = rpm("CVE-2099-0001", "High", "openssl-libs", "1:3.5.8-1.el9_8")

    rows = [
      row("CVE-2099-0001", "openssl-libs-1:3.5.8-1.el9_8"),
      row("CVE-2099-0009", "pcre2-10.40-6.el9")
    ]

    assert [violation] = gate([current], rows)

    assert violation =~
             ~r/^AC4: .* justifies CVE-2099-0009 in pcre2-10\.40-6\.el9 at pkgdb, which the scan no longer reports/
  end

  test "AC4: upgrading the package retires the row, because the key includes the version" do
    upgraded = rpm("CVE-2099-0001", "High", "openssl-libs", "1:3.5.9-1.el9_8")

    [unjustified, stale] =
      gate([upgraded], [row("CVE-2099-0001", "openssl-libs-1:3.5.8-1.el9_8")])

    assert unjustified =~ "AC3: CVE-2099-0001 (high) in openssl-libs-1:3.5.9-1.el9_8"
    assert stale =~ "AC4: "
  end

  test "a row with no justification text, or missing a key, is refused" do
    finding = rpm("CVE-2099-0001", "High", "openssl-libs", "1:3.5.8-1.el9_8")
    blank = Map.put(row("CVE-2099-0001", "openssl-libs-1:3.5.8-1.el9_8"), "justification", "  ")
    keyless = Map.delete(row("CVE-2099-0001", "openssl-libs-1:3.5.8-1.el9_8"), "scanSource")

    for bad <- [blank, keyless] do
      found = gate([finding], [bad])
      assert Enum.any?(found, &(&1 =~ "AC3: malformed justification row")), inspect(found)

      assert Enum.any?(found, &(&1 =~ "AC3: CVE-2099-0001 (high)")),
             "a malformed row must not justify"
    end
  end

  test "the same finding reported twice is one finding" do
    match = rpm("CVE-2099-0001", "High", "openssl-libs", "1:3.5.8-1.el9_8")
    assert length(Findings.findings(%{"matches" => [match, match]})) == 1
  end

  test "the CSV carries every finding with its justification, quoting commas" do
    findings =
      Findings.findings(%{"matches" => [rpm("CVE-2099-0001", "High", "pcre2", "10.40-6.el9")]})

    row = Map.put(row("CVE-2099-0001", "pcre2-10.40-6.el9"), "justification", "inherited, no fix")
    csv = findings |> Findings.evaluate([row]) |> Findings.to_csv()

    assert csv ==
             "finding,severity,scanSource,package,packagePath,fix,justification\n" <>
               "CVE-2099-0001,high,grype,pcre2-10.40-6.el9,,not-fixed,\"inherited, no fix\"\n"
  end

  test "the justification file in the tree is well formed" do
    {:ok, data} = YamlElixir.read_from_file("ci/headless/justifications.yaml")
    rows = data["justifications"]
    assert rows != []
    assert Findings.evaluate([], rows).invalid == []
  end

  describe "the task" do
    @describetag :tmp_dir

    test "fails on an unjustified finding and passes once justified, writing the CSV", %{
      tmp_dir: tmp
    } do
      scan = Path.join(tmp, "grype.json")
      rows = Path.join(tmp, "justifications.yaml")
      out = Path.join(tmp, "findings.csv")

      File.write!(
        scan,
        Jason.encode!(%{"matches" => [rpm("CVE-2099-0001", "High", "zlib", "1.2.11")]})
      )

      File.write!(rows, "justifications: []\n")

      assert_raise Mix.Error, ~r/1 violation/, fn ->
        Findings.run(["--scan", scan, "--justifications", rows, "--out", out])
      end

      File.write!(rows, """
      justifications:
        - finding: "CVE-2099-0001"
          package: "zlib-1.2.11"
          packagePath: null
          severity: "high"
          scanSource: "grype"
          justification: "Planted for this test."
      """)

      assert :ok == Findings.run(["--scan", scan, "--justifications", rows, "--out", out])

      assert File.read!(out) =~
               "CVE-2099-0001,high,grype,zlib-1.2.11,,not-fixed,Planted for this test."
    end

    test "says how to call it without --scan" do
      assert_raise Mix.Error, ~r/usage/, fn -> Findings.run([]) end
    end
  end
end
