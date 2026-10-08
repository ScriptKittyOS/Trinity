# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule ImageSupplyChainDocTest do
  @moduledoc """
  Slice 131, AC6 and AC4, the parts that need no tools: the verification block is where the
  tests and the publishing job look for it, the job runs it, and the page states the level
  `ci/headless/slsa.yaml` claims. `ImageSupplyChainTest` below runs the block itself.
  """
  use ExUnit.Case, async: true

  @doc_path "docs/regulated/image-verify.md"
  @workflow ".github/workflows/headless-image.yml"
  @script "scripts/image_supply_chain.sh"

  @doc "The verification block of the page: the text of the bash fence between the two markers."
  @spec verify_block(String.t()) :: String.t()
  def verify_block(text) do
    [_, inside] = String.split(text, "<!-- verify:begin -->", parts: 2)
    [inside, _] = String.split(inside, "<!-- verify:end -->", parts: 2)
    [_, fence] = Regex.run(~r/\A\s*```bash\n(.*)```\s*\z/s, inside)
    fence
  end

  describe "the documented sequence, without the tools" do
    test "the page carries exactly one block between the markers, a bash fence" do
      text = File.read!(@doc_path)
      assert length(String.split(text, "<!-- verify:begin -->")) == 2
      assert length(String.split(text, "<!-- verify:end -->")) == 2
      block = verify_block(text)
      assert block =~ ~s("$COSIGN" verify )
      assert block =~ "statements slsaprovenance1"
    end

    test "the publishing job extracts the same block from the same page and runs it" do
      workflow = File.read!(@workflow)
      assert workflow =~ "<!-- verify:begin -->"
      assert workflow =~ "<!-- verify:end -->"
      assert workflow =~ @doc_path
    end

    test "the block and the producer script name the same AI-BOM predicate type" do
      {type, 0} = System.cmd("bash", [@script, "aibom-type"])
      assert verify_block(File.read!(@doc_path)) =~ ~s(AIBOM_TYPE="#{String.trim(type)}")
    end

    test "the page states the SLSA level ci/headless/slsa.yaml claims, and no other" do
      {:ok, %{"build_level" => level}} = YamlElixir.read_from_file("ci/headless/slsa.yaml")
      text = File.read!(@doc_path)

      assert text =~ "**Claimed: SLSA Build L#{level}**"
      claimed = Regex.scan(~r/Claimed: SLSA Build L(\d)/, text) |> Enum.map(&List.last/1)
      assert claimed == [Integer.to_string(level)]
    end
  end
end

defmodule ImageSupplyChainTest do
  @moduledoc """
  Slice 131: the published image's signature, provenance, SBOM and AI-BOM, checked the way a
  stranger checks them, by running the exact sequence `docs/regulated/image-verify.md` documents
  (AC6), extracted from the page at run time.

  The `:image_signing` cases (AC1, AC2, AC3, AC6, AC7's attestation) push small images to a
  `registry:2` container on the loopback, sign and attest them with `scripts/image_supply_chain.sh`
  and the real cosign (`TRINITY_COSIGN`), save each as an OCI layout with `cosign save`, stop
  nothing else, and run the documented block against the layout. The genuine case passes, and
  each tampering fails at its own step with its own exit status, which is asserted, along with the
  `FAIL <step>` line the block printed. Keys are made by the test, in its own directory.

  Every case here is tagged `:image_signing` (test/test_helper.exs). The parts that need no tools
  are `ImageSupplyChainDocTest` above.
  """
  use ExUnit.Case, async: false

  @moduletag :image_signing
  @moduletag timeout: 600_000

  alias Mix.Tasks.Trinity.Image.{Aibom, Provenance}

  @doc_path "docs/regulated/image-verify.md"
  @script "scripts/image_supply_chain.sh"
  @registry_image "registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
  @repository "https://github.com/ScriptKittyOS/Trinity"
  @builder "https://github.com/ScriptKittyOS/Trinity/.github/workflows/headless-image.yml@refs/heads/main"
  @commit String.duplicate("c1", 20)
  @other_commit String.duplicate("d2", 20)
  # Not empty: an empty value in a port's environment unsets the variable, and cosign then waits
  # for a password on the terminal (observed: generate-key-pair never returned).
  @password "s131-test-only"

  setup_all do
    cosign = System.fetch_env!("TRINITY_COSIGN")

    assert File.regular?(cosign),
           "TRINITY_COSIGN=#{cosign} names no file; set it to the cosign program or unset it"

    for tool <- ~w(docker jq sha256sum) do
      assert System.find_executable(tool), "#{tool} is not on PATH"
    end

    dir = Path.join(System.tmp_dir!(), "s131-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = "s131-registry-#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd("docker", ~w(run -d --rm --name #{name} -p 127.0.0.1::5000 #{@registry_image}))

    {port_line, 0} = System.cmd("docker", ["port", name, "5000/tcp"])
    [port] = Regex.run(~r/:(\d+)\s*\z/, String.trim(port_line), capture: :all_but_first)
    registry = "127.0.0.1:#{port}"

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)
      {tags, _} = System.cmd("docker", ["images", "--format", "{{.Repository}}:{{.Tag}}"])

      for t <- String.split(tags, "\n", trim: true), String.starts_with?(t, registry <> "/") do
        System.cmd("docker", ["rmi", "-f", t], stderr_to_stdout: true)
      end

      File.rm_rf!(dir)
    end)

    key = keypair!(cosign, dir, "project")
    other = keypair!(cosign, dir, "other")

    %{cosign: cosign, dir: dir, registry: registry, key: key, other_key: other}
  end

  setup ctx do
    Map.put(ctx, :case_dir, mkdir!(ctx.dir, "case-#{System.unique_integer([:positive])}"))
  end

  test "AC1 to AC3, AC6, AC7: the genuine image passes every step", ctx do
    ref = push!(ctx, "genuine", @commit)
    bills = bills!(ctx)
    attach!(ctx, ref, bills)
    layout = save!(ctx, ref)

    {out, 0} = verify(ctx, layout, reference_sbom: bills.sbom)

    for step <- ~w(layout signature commit builder sbom sbom-match aibom) do
      assert out =~ ~r/^OK #{step}: /m, "no OK line for #{step} in:\n#{out}"
    end

    assert out =~ "the image and its provenance both name #{@commit}"
  end

  test "AC1 red: an image this tree did not sign (main has no signing) is refused", ctx do
    ref = push!(ctx, "unsigned", @commit)
    assert_fails(verify(ctx, save!(ctx, ref)), "signature", 11)
  end

  test "AC1 red: another image pushed under the signed image's tag is refused", ctx do
    ref = push!(ctx, "moved-tag", @commit, tag: "release")
    attach!(ctx, ref, bills!(ctx))
    _replaced = push!(ctx, "moved-tag-replacement", @commit, repo: "moved-tag", tag: "release")

    layout = save!(ctx, "#{ctx.registry}/s131/moved-tag:release")
    assert_fails(verify(ctx, layout), "signature", 11)
  end

  test "AC1 red: the genuine signatures moved onto another image are refused", ctx do
    signed = push!(ctx, "donor", @commit)
    attach!(ctx, signed, bills!(ctx))
    donor = save!(ctx, signed)
    target = save!(ctx, push!(ctx, "recipient", @commit))

    transplant!(donor, target)
    assert_fails(verify(ctx, target), "signature", 11)
  end

  test "AC1 red: a layer altered in the layout is refused (cosign alone accepts it)", ctx do
    ref = push!(ctx, "altered-layer", @commit)
    attach!(ctx, ref, bills!(ctx))
    layout = save!(ctx, ref)

    layer = layer_blob(layout)
    bytes = File.read!(layer)
    <<head::binary-size(20), b, rest::binary>> = bytes
    File.write!(layer, <<head::binary, Bitwise.bxor(b, 1), rest::binary>>)

    {_, cosign_status} = cosign_verify(ctx, layout, ctx.key.pub)
    assert cosign_status == 0, "cosign verify now checks layers; the layout step is still needed"

    assert_fails(verify(ctx, layout), "layout", 10)
  end

  test "AC1 red: a signature by another key is refused", ctx do
    ref = push!(ctx, "other-key", @commit)
    attach!(ctx, ref, bills!(ctx), key: ctx.other_key)
    assert_fails(verify(ctx, save!(ctx, ref)), "signature", 11)
  end

  test "AC2 red: a provenance whose commit does not match the image is refused", ctx do
    ref = push!(ctx, "wrong-commit", @commit)
    attach!(ctx, ref, bills!(ctx, commit: @other_commit))

    {out, status} = verify(ctx, save!(ctx, ref))
    assert_fails({out, status}, "commit", 13)
    assert out =~ "the provenance names another commit than #{@commit}"
  end

  test "AC2 red: an image built from another commit than the one expected is refused", ctx do
    ref = push!(ctx, "other-expected", @commit)
    attach!(ctx, ref, bills!(ctx))

    {out, status} = verify(ctx, save!(ctx, ref), commit: @other_commit)
    assert_fails({out, status}, "commit", 13)
    assert out =~ "the image says it was built from '#{@commit}', not #{@other_commit}"
  end

  test "AC2 red: an image with no provenance is refused", ctx do
    ref = push!(ctx, "no-provenance", @commit)
    sign_only!(ctx, ref)
    assert_fails(verify(ctx, save!(ctx, ref)), "provenance", 12)
  end

  test "AC2 red: a provenance from another builder is refused", ctx do
    ref = push!(ctx, "other-builder", @commit)
    attach!(ctx, ref, bills!(ctx, builder: "https://example.invalid/builder"))
    assert_fails(verify(ctx, save!(ctx, ref)), "builder", 14)
  end

  test "AC3 red: an SBOM that drifted from the tree's bill for the commit is refused", ctx do
    ref = push!(ctx, "drifted-sbom", @commit)
    bills = bills!(ctx)
    drifted = Path.join(ctx.case_dir, "drifted.cdx.json")

    bills.sbom
    |> File.read!()
    |> Jason.decode!()
    |> update_in(["components", Access.at(0), "version"], fn _ -> "9.9.9" end)
    |> then(&File.write!(drifted, Jason.encode!(&1)))

    attach!(ctx, ref, %{bills | sbom: drifted})

    {out, status} = verify(ctx, save!(ctx, ref), reference_sbom: bills.sbom)
    assert_fails({out, status}, "sbom-match", 16)
  end

  test "AC7: an AI-BOM whose dataset list was removed is refused", ctx do
    ref = push!(ctx, "no-datasets", @commit)
    bills = bills!(ctx)
    stripped = Path.join(ctx.case_dir, "stripped.cdx.json")

    bills.aibom
    |> File.read!()
    |> Jason.decode!()
    |> update_in(["components"], fn cs ->
      Enum.map(cs, fn
        %{"type" => "machine-learning-model"} = c ->
          update_in(c, ["modelCard", "modelParameters"], &Map.delete(&1, "datasets"))

        c ->
          c
      end)
    end)
    |> then(&File.write!(stripped, Jason.encode!(&1)))

    attach!(ctx, ref, %{bills | aibom: stripped})
    assert_fails(verify(ctx, save!(ctx, ref)), "aibom", 17)
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp mkdir!(parent, name) do
    path = Path.join(parent, name)
    File.mkdir_p!(path)
    path
  end

  defp keypair!(cosign, dir, name) do
    {out, status} =
      System.cmd(cosign, ["generate-key-pair", "--output-key-prefix", Path.join(dir, name)],
        env: [{"COSIGN_PASSWORD", @password}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    %{key: Path.join(dir, name <> ".key"), pub: Path.join(dir, name <> ".pub")}
  end

  # A two-file image FROM scratch, labelled with its commit the way headless_image.sh labels one.
  defp push!(ctx, name, commit, opts \\ []) do
    context = mkdir!(ctx.dir, "img-#{name}-#{System.unique_integer([:positive])}")
    File.write!(Path.join(context, "Dockerfile"), "FROM scratch\nCOPY payload.txt /payload.txt\n")
    File.write!(Path.join(context, "payload.txt"), "#{name} #{System.unique_integer()}\n")
    repo = "#{ctx.registry}/s131/#{opts[:repo] || name}"
    tag = "#{repo}:#{opts[:tag] || "1"}"

    {out, status} =
      System.cmd(
        "docker",
        ["build", "-q", "--label", "org.opencontainers.image.revision=#{commit}"] ++
          ["--label", "org.opencontainers.image.source=#{@repository}", "-t", tag, context],
        stderr_to_stdout: true
      )

    assert status == 0, out
    {out, status} = System.cmd("docker", ["push", tag], stderr_to_stdout: true)
    assert status == 0, out
    [_, digest] = Regex.run(~r/digest: (sha256:[0-9a-f]{64})/, out)
    "#{repo}@#{digest}"
  end

  defp bills!(ctx, opts \\ []) do
    dir = mkdir!(ctx.case_dir, "bills-#{System.unique_integer([:positive])}")

    params = %{
      commit: opts[:commit] || @commit,
      repository: @repository,
      builder_id: opts[:builder] || @builder,
      ref: "refs/heads/main",
      invocation: nil
    }

    provenance =
      Provenance.predicate(
        params,
        Provenance.read_resources!("ci/ironbank/hardening_manifest.yaml"),
        Provenance.read_bases!("ci/headless/bases.env")
      )

    sbom = %{
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.6",
      "version" => 1,
      "components" => [
        %{
          "type" => "library",
          "group" => "hexpm",
          "name" => "jason",
          "version" => "1.4.5",
          "purl" => "pkg:hex/jason@1.4.5"
        },
        %{
          "type" => "library",
          "group" => "hexpm",
          "name" => "jcs",
          "version" => "0.2.0",
          "purl" => "pkg:hex/jcs@0.2.0"
        }
      ]
    }

    aibom = Aibom.bom(Aibom.read_models!("test/support/fixtures/supply_chain/models.yaml"))

    for {name, doc} <- [provenance: provenance, sbom: sbom, aibom: aibom], into: %{} do
      path = Path.join(dir, "#{name}.json")
      File.write!(path, Jason.encode!(doc))
      {name, path}
    end
  end

  defp attach!(ctx, ref, bills, opts \\ []) do
    key = (opts[:key] || ctx.key).key

    {out, status} =
      System.cmd(
        "bash",
        [@script, "attach", ref, "--key", key] ++
          ["--provenance", bills.provenance, "--sbom", bills.sbom, "--aibom", bills.aibom],
        env: cosign_env(ctx),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  defp sign_only!(ctx, ref) do
    {out, status} =
      System.cmd(
        ctx.cosign,
        ~w(sign --yes --key #{ctx.key.key} --use-signing-config=false --tlog-upload=false
           --allow-insecure-registry --allow-http-registry #{ref}),
        env: [{"COSIGN_PASSWORD", @password}],
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  defp cosign_env(ctx),
    do: [{"COSIGN", ctx.cosign}, {"COSIGN_PASSWORD", @password}, {"IMAGE_REGISTRY_INSECURE", "1"}]

  defp save!(ctx, ref) do
    layout = Path.join(ctx.case_dir, "layout-#{System.unique_integer([:positive])}")

    {out, status} =
      System.cmd(
        ctx.cosign,
        ["save", "--allow-insecure-registry", "--allow-http-registry", "--dir", layout, ref],
        stderr_to_stdout: true
      )

    assert status == 0, out
    layout
  end

  defp cosign_verify(ctx, layout, pub) do
    System.cmd(
      ctx.cosign,
      [
        "verify",
        "--key",
        pub,
        "--offline",
        "--insecure-ignore-tlog=true",
        "--local-image",
        layout
      ],
      stderr_to_stdout: true
    )
  end

  # Runs the page's block, exactly as extracted, in bash, with the inputs as the page names them.
  defp verify(ctx, layout, opts \\ []) do
    script = Path.join(ctx.case_dir, "verify-#{System.unique_integer([:positive])}.sh")
    File.write!(script, ImageSupplyChainDocTest.verify_block(File.read!(@doc_path)))

    env =
      [
        {"LAYOUT", layout},
        {"PUBKEY", ctx.key.pub},
        {"COMMIT", opts[:commit] || @commit},
        {"REPOSITORY", @repository},
        {"BUILDER", @builder},
        {"COSIGN", ctx.cosign},
        {"REFERENCE_SBOM", opts[:reference_sbom]}
      ]

    System.cmd("bash", [script], env: env, stderr_to_stdout: true, cd: ctx.case_dir)
  end

  defp assert_fails({out, status}, step, expected) do
    assert status == expected,
           "expected exit #{expected} at #{step}, got #{status}:\n#{out}"

    assert out =~ ~r/^FAIL #{step}: /m, "no FAIL #{step} line in:\n#{out}"
  end

  # The image manifest's first layer, as a blob path of the layout.
  defp layer_blob(layout) do
    [entry] =
      layout |> Path.join("index.json") |> File.read!() |> Jason.decode!() |> Map.get("manifests")

    manifest = blob_json(layout, entry["digest"])
    [%{"digest" => digest} | _] = manifest["layers"]
    blob_path(layout, digest)
  end

  # Copies every referrer of the donor's image into the target layout, its subject rewritten to
  # the target's image: the genuine signatures, now claiming another image (NOTES, M4).
  defp transplant!(donor, target) do
    [%{"digest" => donor_digest}] = index(donor)
    [%{"digest" => target_digest}] = index(target)

    for file <- File.ls!(Path.join([donor, "blobs", "sha256"])),
        json = decode(File.read!(Path.join([donor, "blobs", "sha256", file]))),
        match?(%{"subject" => %{"digest" => ^donor_digest}}, json) do
      moved = Jason.encode!(put_in(json, ["subject", "digest"], target_digest))
      hex = :crypto.hash(:sha256, moved) |> Base.encode16(case: :lower)
      File.write!(blob_path(target, "sha256:" <> hex), moved)

      for %{"digest" => d} <- json["layers"] do
        File.cp!(blob_path(donor, d), blob_path(target, d))
      end
    end
  end

  defp index(layout),
    do:
      layout |> Path.join("index.json") |> File.read!() |> Jason.decode!() |> Map.get("manifests")

  defp blob_path(layout, "sha256:" <> hex), do: Path.join([layout, "blobs", "sha256", hex])

  defp blob_json(layout, digest),
    do: layout |> blob_path(digest) |> File.read!() |> Jason.decode!()

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end
end
