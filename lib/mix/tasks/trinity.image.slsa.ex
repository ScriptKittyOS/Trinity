# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Image.Slsa do
  @shortdoc "Fails when the claimed SLSA build level is above what the workflow's mechanism justifies (slice 131, AC4)"

  @moduledoc """
  Compares the SLSA build level this project claims for the headless image
  (`ci/headless/slsa.yaml`) with the level the publishing workflow's mechanism can justify, read
  from `.github/workflows/headless-image.yml`, and fails when the claim is the higher of the two.

      mix trinity.image.slsa [--claim PATH] [--workflow PATH]

  The levels are the SLSA build track's (`spec/build-track-basics.md` in slsa-framework/slsa):

  * **L1, provenance exists.** A job attaches provenance to the image: it runs
    `mix trinity.image.provenance` and `scripts/image_supply_chain.sh attach`, and that script
    attests the predicate as `slsaprovenance1`.
  * **L2, a hosted platform generates and signs it.** L1, plus the same job runs on a
    GitHub-hosted runner with `id-token: write` and `attestations: write`, asks GitHub for its
    platform provenance with `actions/attest-build-provenance` pinned by commit and pushed to the
    registry, and verifies it with `gh attestation verify`. GitHub documents its artifact
    attestations as SLSA v1.0 Build Level 2.
  * **L3, the signing secret is out of reach of the build steps.** L2, plus the provenance comes
    from a job-level reusable workflow (`slsa-framework/slsa-github-generator`'s container
    generator), and no job that runs steps of its own holds `id-token: write`.

  A mechanism in a file is not a mechanism that has worked, so a claim of L2 or more must also
  cite at least one workflow run whose verification passed (`evidence:`). The claim file states
  the reason for its level and why it is not the next; both must be present.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @claim "ci/headless/slsa.yaml"
  @workflow ".github/workflows/headless-image.yml"
  @script "scripts/image_supply_chain.sh"
  @attest ~r/\Aactions\/attest-build-provenance@[0-9a-f]{40}\z/
  @generator "slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@"
  @hosted ~r/\A(ubuntu|windows|macos)-[0-9a-z.]+\z/
  @run_url ~r/\Ahttps:\/\/github\.com\/[^\/]+\/[^\/]+\/actions\/runs\/[0-9]+/

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [claim: :string, workflow: :string])
    claim = read_yaml!(opts[:claim] || @claim)
    workflow = read_yaml!(opts[:workflow] || @workflow)
    script = File.read!(@script)
    {level, reasons} = justified(workflow, script)

    Mix.shell().info(
      "trinity.image.slsa: claimed Build L#{inspect(claim["build_level"])}; " <>
        "the workflow's mechanism supports L#{level}"
    )

    Enum.each(reasons, &Mix.shell().info("  not L#{level + 1}: #{&1}"))

    case violations(claim, level) do
      [] ->
        Mix.shell().info("trinity.image.slsa: OK")

      found ->
        Enum.each(found, &Mix.shell().error("FAIL AC4: #{&1}"))
        Mix.raise("trinity.image.slsa: #{length(found)} violation(s)")
    end
  end

  defp read_yaml!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = map} -> map
      other -> Mix.raise("#{path} is not a YAML map: #{inspect(other)}")
    end
  end

  @doc """
  The highest level the workflow's mechanism supports, and why it is not the next one: the
  missing pieces of the next level, as sentences.
  """
  @spec justified(map(), String.t()) :: {0..3, [String.t()]}
  def justified(workflow, script) do
    jobs = Map.get(workflow, "jobs") || %{}
    publish = Enum.find_value(jobs, fn {_, job} -> if publishes?(job), do: job end)

    levels = [
      {1, l1_missing(publish, script)},
      {2, l2_missing(publish)},
      {3, l3_missing(jobs)}
    ]

    Enum.reduce_while(levels, {0, []}, fn {n, missing}, {level, _} ->
      if missing == [], do: {:cont, {n, []}}, else: {:halt, {level, missing}}
    end)
  end

  defp steps(nil), do: []
  defp steps(job), do: List.wrap(job["steps"])

  defp runs?(job, text), do: Enum.any?(steps(job), &String.contains?(&1["run"] || "", text))

  defp publishes?(job), do: runs?(job, "#{@script} attach")

  defp l1_missing(nil, _script),
    do: ["no job runs `#{@script} attach`, so nothing attaches provenance to the image"]

  defp l1_missing(job, script) do
    [
      {runs?(job, "mix trinity.image.provenance"),
       "the publishing job does not generate provenance (`mix trinity.image.provenance`)"},
      {String.contains?(script, "--type slsaprovenance1"),
       "#{@script} does not attest a `slsaprovenance1` predicate"}
    ]
    |> missing()
  end

  defp l2_missing(nil), do: ["no publishing job"]

  defp l2_missing(job) do
    permissions = job["permissions"] || %{}

    attest =
      Enum.find(steps(job), fn s -> is_binary(s["uses"]) and Regex.match?(@attest, s["uses"]) end)

    [
      {is_binary(job["runs-on"]) and Regex.match?(@hosted, job["runs-on"]),
       "the publishing job does not run on a GitHub-hosted runner"},
      {permissions["id-token"] == "write" and permissions["attestations"] == "write",
       "the publishing job does not hold `id-token: write` and `attestations: write`"},
      {attest != nil,
       "no step asks GitHub for platform provenance (`actions/attest-build-provenance` pinned by commit)"},
      {attest != nil and get_in(attest, ["with", "push-to-registry"]) in [true, "true"],
       "the platform provenance is not pushed to the registry beside the image"},
      {runs?(job, "gh attestation verify"),
       "no step verifies the platform provenance (`gh attestation verify`)"}
    ]
    |> missing()
  end

  defp l3_missing(jobs) do
    generator? =
      Enum.any?(jobs, fn {_, job} ->
        is_binary(job["uses"]) and String.starts_with?(job["uses"], @generator)
      end)

    stepping_with_identity =
      for {name, job} <- jobs,
          steps(job) != [],
          get_in(job, ["permissions", "id-token"]) == "write",
          do: name

    [
      {generator?,
       "the provenance is made in the same job as the build's own steps, not by an isolated " <>
         "reusable workflow (#{String.trim_trailing(@generator, "@")})"},
      {stepping_with_identity == [],
       "job(s) #{Enum.join(Enum.sort(stepping_with_identity), ", ")} run their own steps while " <>
         "holding `id-token: write`, so the signing identity is in reach of those steps"}
    ]
    |> missing()
  end

  defp missing(checks), do: checks |> Enum.reject(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  @doc "Why the claim cannot stand against a justified level; `[]` when it can."
  @spec violations(map(), 0..3) :: [String.t()]
  def violations(claim, justified) do
    level = claim["build_level"]
    evidence = List.wrap(claim["evidence"])

    cond do
      level not in 0..3 ->
        ["build_level #{inspect(level)} is not a SLSA build level (0 to 3)"]

      level > justified ->
        [
          "Build L#{level} is claimed, and the workflow's mechanism supports only L#{justified}"
        ]

      true ->
        [
          {level < 2 or (evidence != [] and Enum.all?(evidence, &run_url?/1)),
           "Build L#{level} is claimed without a workflow run whose verification passed " <>
             "(`evidence:` lists none)"},
          {present?(claim["reason"]), "the claim states no reason for its level (`reason:`)"},
          {level == 3 or present?(claim["not_next"]),
           "the claim does not say why it is not L#{level + 1} (`not_next:`)"}
        ]
        |> missing()
    end
  end

  defp run_url?(url), do: is_binary(url) and Regex.match?(@run_url, url)
  defp present?(text), do: is_binary(text) and String.trim(text) != ""
end
