# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.StigTest do
  @moduledoc """
  Slice 130, AC5: the STIG applicability statement is derived from OpenSCAP's results, every
  selected rule gets a disposition, and a rule with none fails the check. The results here are a
  small XCCDF 1.2 document in OpenSCAP's shape; the run on the built image's real results (477
  rules) is in the slice's PROOF.md.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Image.Stig

  @moduletag :tmp_dir

  @results """
  <?xml version="1.0" encoding="UTF-8"?>
  <Benchmark xmlns="http://checklists.nist.gov/xccdf/1.2" id="xccdf_org.ssgproject.content_benchmark_RHEL-9">
    <Group id="xccdf_org.ssgproject.content_group_system">
      <platform idref="#machine"/>
      <Rule id="rule_audit" selected="false" severity="medium">
        <title>Enable auditd</title>
        <reference href="https://www.cyber.mil/stigs/downloads/">RHEL-09-653010</reference>
        <reference href="https://www.cyber.mil/stigs/srg-stig-tools/">SV-1_rule</reference>
      </Rule>
    </Group>
    <Group id="xccdf_org.ssgproject.content_group_accounts">
      <Rule id="rule_umask" selected="false" severity="medium">
        <title>Ensure the Default Bash Umask is Set Correctly</title>
        <description>umask <sub/></description>
        <platform idref="#package_bash"/>
        <reference href="https://www.cyber.mil/stigs/downloads/">RHEL-09-412055</reference>
      </Rule>
      <Rule id="rule_resolv" selected="false" severity="medium">
        <title>Configure Multiple DNS Servers</title>
        <reference href="https://www.cyber.mil/stigs/downloads/">RHEL-09-252035</reference>
      </Rule>
      <Rule id="rule_unselected" selected="false" severity="low"><title>Not in the profile</title></Rule>
    </Group>
    <TestResult id="tr" version="0.1.82" end-time="2026-10-08T06:36:15+00:00">
      <profile idref="xccdf_org.ssgproject.content_profile_stig"/>
      <target-facts><fact name="urn:xccdf:fact:scanner:version" type="string">1.3.14</fact></target-facts>
      <platform idref="#package_bash"/>
      <rule-result idref="rule_audit"><result>notapplicable</result></rule-result>
      <rule-result idref="rule_umask"><result>pass</result></rule-result>
      <rule-result idref="rule_resolv"><result>fail</result></rule-result>
      <rule-result idref="rule_unselected"><result>notselected</result></rule-result>
    </TestResult>
  </Benchmark>
  """

  @deployment %{
    "rules" => ["rule_resolv"],
    "disposition" => "deployment",
    "reason" => "the runtime writes resolv.conf"
  }

  setup_all do
    Mix.ensure_application!(:xmerl)
    :ok
  end

  setup %{tmp_dir: tmp} do
    path = Path.join(tmp, "results.xml")
    File.write!(path, @results)
    %{scan: Stig.read_results(path)}
  end

  test "reads the selected rules, their STIG identifiers and their groups' platforms", %{
    scan: scan
  } do
    assert scan.profile == "xccdf_org.ssgproject.content_profile_stig"
    assert {scan.version, scan.scanner} == {"0.1.82", "1.3.14"}
    assert Enum.map(scan.rules, & &1.id) == ["rule_audit", "rule_umask", "rule_resolv"]

    [audit, umask, _] = scan.rules

    assert {audit.title, audit.stig, audit.platforms, audit.result} ==
             {"Enable auditd", ["RHEL-09-653010"], ["#machine"], "notapplicable"}

    assert {umask.platforms, umask.result} == {["#package_bash"], "pass"}
  end

  test "pass is met and notapplicable is not applicable, with OpenSCAP's own reason", %{
    scan: scan
  } do
    {disposed, []} = Stig.dispose(scan.rules, [@deployment])

    assert Enum.map(disposed, fn {rule, d, reason} -> {rule.id, d, reason} end) == [
             {"rule_audit", "not applicable",
              "OpenSCAP: notapplicable; the rule applies only where machine holds"},
             {"rule_umask", "met", "OpenSCAP: pass"},
             {"rule_resolv", "the deployment's", "the runtime writes resolv.conf"}
           ]
  end

  test "a rule with no disposition fails the check (planted red), and passes once it has one", %{
    scan: scan
  } do
    assert {_, [violation]} = Stig.dispose(scan.rules, [])

    assert violation ==
             "AC5: RHEL-09-252035 (rule_resolv) is fail and has no disposition in ci/headless/stig_dispositions.yaml"

    assert {_, []} = Stig.dispose(scan.rules, [@deployment])
  end

  test "a row for a rule that now passes, or that the profile does not select, is stale", %{
    scan: scan
  } do
    stale = %{"rules" => ["rule_umask"], "disposition" => "met", "reason" => "was fixed by hand"}

    unknown = %{
      "rules" => ["rule_gone"],
      "disposition" => "deployment",
      "reason" => "no longer in the guide"
    }

    {_, violations} = Stig.dispose(scan.rules, [@deployment, stale, unknown])

    assert violations == [
             "AC5: RHEL-09-412055 (rule_umask) is pass now; remove its row from ci/headless/stig_dispositions.yaml",
             "AC5: ci/headless/stig_dispositions.yaml disposes of rule_gone, which the profile does not select"
           ]
  end

  test "a malformed or duplicated row is refused, and a malformed row disposes of nothing", %{
    scan: scan
  } do
    blank = %{"rules" => ["rule_resolv"], "disposition" => "waived", "reason" => " "}
    {_, violations} = Stig.dispose(scan.rules, [blank])

    assert "AC5: RHEL-09-252035 (rule_resolv) is fail and has no disposition in ci/headless/stig_dispositions.yaml" in violations

    assert Enum.any?(violations, &(&1 =~ "disposition must be met, not_applicable or deployment"))
    assert Enum.any?(violations, &(&1 =~ "needs a reason"))

    {_, violations} = Stig.dispose(scan.rules, [@deployment, @deployment])
    assert violations == ["AC5: rule_resolv has more than one disposition"]
  end

  test "the statement says what it is and is not, and carries every rule", %{scan: scan} do
    {disposed, violations} = Stig.dispose(scan.rules, [@deployment])

    text =
      Stig.statement(scan, disposed, violations,
        image: "trinity-headless:test",
        digest: "sha256:abc"
      )

    assert text =~ "This is a statement about an image, not a compliance determination."
    assert text =~ "| Image ID | sha256:abc |"
    assert text =~ "3 rules selected."

    assert text =~
             "| RHEL-09-252035 | Configure Multiple DNS Servers | medium | fail | the deployment's | the runtime writes resolv.conf |"

    assert text =~ "Every rule has a disposition."
  end

  test "the dispositions file in the tree is well formed" do
    {:ok, %{"dispositions" => rows}} =
      YamlElixir.read_from_file("ci/headless/stig_dispositions.yaml")

    rules =
      for row <- rows,
          id <- row["rules"],
          do: %{id: id, title: "", stig: [], platforms: [], severity: "", result: "fail"}

    assert {_, []} = Stig.dispose(rules, rows)
  end

  test "the task writes the statement and fails while a rule has no disposition", %{tmp_dir: tmp} do
    results = Path.join(tmp, "results.xml")
    rows = Path.join(tmp, "dispositions.yaml")
    out = Path.join(tmp, "statement.md")
    File.write!(results, @results)
    File.write!(rows, "dispositions: []\n")

    assert_raise Mix.Error, ~r/1 violation/, fn ->
      Stig.run(["--results", results, "--dispositions", rows, "--out", out])
    end

    assert File.read!(out) =~ "**Rules without a disposition, or rows that need attention:**"

    File.write!(rows, """
    dispositions:
      - rules: ["rule_resolv"]
        disposition: "deployment"
        reason: "the runtime writes resolv.conf"
    """)

    assert :ok ==
             Stig.run([
               "--results",
               results,
               "--dispositions",
               rows,
               "--out",
               out,
               "--image",
               "img",
               "--digest",
               "sha256:1"
             ])

    assert File.read!(out) =~ "Every rule has a disposition."
  end
end
