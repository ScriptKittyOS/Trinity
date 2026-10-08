# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.SlsaTest do
  @moduledoc """
  Slice 131, AC4: the SLSA build level claimed for the headless image cannot be raised above
  what the publishing workflow's mechanism supports, nor to L2 or more without a run that
  verified, and the claim states its reason and why it is not the next level.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Trinity.Image.Slsa

  @workflow ".github/workflows/headless-image.yml"
  @claim "ci/headless/slsa.yaml"
  @script "scripts/image_supply_chain.sh"

  defp yaml!(path) do
    {:ok, map} = YamlElixir.read_from_file(path)
    map
  end

  defp workflow, do: yaml!(@workflow)
  defp claim, do: yaml!(@claim)
  defp script, do: File.read!(@script)

  defp publish_job(workflow), do: workflow["jobs"]["publish"]

  defp update_publish(fun), do: update_in(workflow(), ["jobs", "publish"], fun)

  defp without_step(job, pred), do: Map.update!(job, "steps", &Enum.reject(&1, pred))

  describe "the tree" do
    test "the claim stands against the workflow's mechanism" do
      {level, _} = Slsa.justified(workflow(), script())
      assert Slsa.violations(claim(), level) == []
    end

    test "the claim is Build L1, the workflow carries L2's mechanism, and L3's is missing" do
      assert claim()["build_level"] == 1
      {level, not_next} = Slsa.justified(workflow(), script())
      assert level == 2
      assert Enum.any?(not_next, &(&1 =~ "not by an isolated reusable workflow"))

      assert Enum.any?(
               not_next,
               &(&1 =~ "publish run their own steps while holding `id-token: write`")
             )
    end

    test "the task passes on the tree" do
      Slsa.run([])
    end
  end

  describe "AC4 red: raising the claim without the mechanism fails" do
    test "L2 claimed with no run that verified" do
      raised = %{claim() | "build_level" => 2}

      assert Slsa.violations(raised, 2) == [
               "Build L2 is claimed without a workflow run whose verification passed " <>
                 "(`evidence:` lists none)"
             ]
    end

    test "L2 claimed with evidence that is not a workflow run" do
      raised = %{claim() | "build_level" => 2, "evidence" => ["it worked on my machine"]}
      assert [msg] = Slsa.violations(raised, 2)
      assert msg =~ "without a workflow run"
    end

    test "L2 claimed, with a run, once the platform provenance step is removed" do
      wf =
        update_publish(
          &without_step(&1, fn s -> (s["uses"] || "") =~ "attest-build-provenance" end)
        )

      {level, missing} = Slsa.justified(wf, script())
      assert level == 1
      assert Enum.any?(missing, &(&1 =~ "no step asks GitHub for platform provenance"))

      raised = %{
        claim()
        | "build_level" => 2,
          "evidence" => ["https://github.com/ScriptKittyOS/Trinity/actions/runs/1"]
      }

      assert Slsa.violations(raised, level) == [
               "Build L2 is claimed, and the workflow's mechanism supports only L1"
             ]
    end

    test "L3 claimed: no isolated provenance generator" do
      raised = %{
        claim()
        | "build_level" => 3,
          "evidence" => ["https://github.com/ScriptKittyOS/Trinity/actions/runs/1"]
      }

      {level, _} = Slsa.justified(workflow(), script())

      assert Slsa.violations(raised, level) == [
               "Build L3 is claimed, and the workflow's mechanism supports only L2"
             ]
    end

    test "L1 claimed when nothing attaches provenance" do
      wf = update_in(workflow(), ["jobs"], &Map.delete(&1, "publish"))
      assert {0, [msg]} = Slsa.justified(wf, script())
      assert msg =~ "nothing attaches provenance"

      assert Slsa.violations(claim(), 0) == [
               "Build L1 is claimed, and the workflow's mechanism supports only L0"
             ]
    end

    test "L1's pieces: the provenance task and the script's provenance attestation" do
      wf =
        update_publish(
          &without_step(&1, fn s -> (s["run"] || "") =~ "trinity.image.provenance" end)
        )

      assert {0, [msg]} = Slsa.justified(wf, script())
      assert msg =~ "does not generate provenance"

      assert {0, [msg]} =
               Slsa.justified(workflow(), String.replace(script(), "slsaprovenance1", "custom"))

      assert msg =~ "does not attest a `slsaprovenance1` predicate"
    end

    test "L2's pieces: a self-hosted runner, the permissions, the push, the verification" do
      for {change, expected} <- [
            {&Map.put(&1, "runs-on", "self-hosted"), "GitHub-hosted runner"},
            {&put_in(&1, ["permissions", "id-token"], "none"), "`id-token: write`"},
            {fn job ->
               Map.update!(job, "steps", fn steps ->
                 Enum.map(steps, fn s ->
                   if (s["uses"] || "") =~ "attest-build-provenance",
                     do: put_in(s, ["with", "push-to-registry"], false),
                     else: s
                 end)
               end)
             end, "not pushed to the registry"},
            {&without_step(&1, fn s -> (s["run"] || "") =~ "gh attestation verify" end),
             "no step verifies the platform provenance"}
          ] do
        assert {1, missing} = Slsa.justified(update_publish(change), script())
        assert Enum.any?(missing, &(&1 =~ expected)), "#{expected} not in #{inspect(missing)}"
      end
    end

    test "a claim with no reason, or no word on the next level" do
      assert Slsa.violations(Map.delete(claim(), "reason"), 2) == [
               "the claim states no reason for its level (`reason:`)"
             ]

      assert Slsa.violations(%{claim() | "not_next" => " "}, 2) == [
               "the claim does not say why it is not L2 (`not_next:`)"
             ]
    end

    test "the task fails on a raised claim", %{} do
      path =
        Path.join(System.tmp_dir!(), "slsa-#{System.unique_integer([:positive])}.yaml")

      File.write!(path, File.read!(@claim) |> String.replace("build_level: 1", "build_level: 2"))
      on_exit(fn -> File.rm(path) end)

      assert_raise Mix.Error, ~r/1 violation/, fn -> Slsa.run(["--claim", path]) end
    end
  end

  test "the publishing job is the one the check reads" do
    assert publish_job(workflow())["needs"] == "image"
  end
end
