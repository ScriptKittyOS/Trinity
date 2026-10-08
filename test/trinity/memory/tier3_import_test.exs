# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Tier3ImportTest do
  @moduledoc """
  Slice 134, AC4: the import path refuses weights whose OMS or cosign signature does not verify
  against the operator's key, offline, and records the resulting digest when they do. Red: one
  flipped byte.

  Two groups:

    * **Everywhere**, through a stand-in verifier that passes: the import path's own checks (a
      flipped byte in a blob against its descriptor, a title that is a path, a symbolic link in
      the layout, the OMS statement against the GGUF, the blob the service names) and the record.
    * **`:signing_tools`**, through the real `cosign` and `model_signing` (`TRINITY_COSIGN`,
      `TRINITY_MODEL_SIGNING`; a failure, never a skip, when set and absent): keys made by the
      test, the OMS signature made by `model_signing` itself, the layout signed in cosign's
      shape (`Trinity.OCILayout`), and each signature broken by one flipped bit.

  The service is `Trinity.FakeOllama` on the loopback. Nothing reaches a network.
  """
  use ExUnit.Case, async: false

  alias Trinity.{FakeOllama, OCILayout, Tier3Helper}
  alias Trinity.Memory.Tier3.Import

  @moduletag :tmp_dir

  defmodule Pass do
    @moduledoc false
    @behaviour Trinity.Memory.Tier3.Verifier
    @impl true
    def cosign(_layout, _key, _opts), do: :ok
    @impl true
    def oms(_dir, _sig, _key, _opts), do: :ok
  end

  setup %{tmp_dir: dir} do
    fake = FakeOllama.start!(Tier3Helper.tokenizer())
    gguf = Tier3Helper.gguf()
    {:ok, fake: fake, gguf: gguf, dir: dir}
  end

  # An OMS bundle whose statement lists `files` (`[{name, bytes}]`), unsigned: for the stand-in
  # verifier, which never looks at the signature.
  defp unsigned_oms(files) do
    resources =
      for {n, b} <- files,
          do: %{"name" => n, "algorithm" => "sha256", "digest" => Tier3Helper.sha256(b)}

    payload =
      Jason.encode!(%{
        "_type" => "https://in-toto.io/Statement/v1",
        "subject" => [%{"name" => "model", "digest" => %{"sha256" => String.duplicate("0", 64)}}],
        "predicateType" => "https://model_signing/signature/v1.0",
        "predicate" => %{"resources" => resources}
      })

    Jason.encode!(%{"dsseEnvelope" => %{"payload" => Base.encode64(payload), "signatures" => []}})
  end

  defp import(dir, layout, fake, extra \\ []) do
    Import.run(
      Keyword.merge(
        [
          layout: layout,
          cosign_key: Path.join(dir, "absent-cosign.pub"),
          oms_key: Path.join(dir, "absent-oms.pub"),
          base_url: fake.url,
          model: "embed-test",
          out: Path.join(dir, "out"),
          staging: Path.join(dir, "staging"),
          verifier: Pass
        ],
        extra
      )
    )
  end

  defp layout!(dir, files, key \\ nil, opts \\ []) do
    path = Path.join(dir, "layout-#{System.unique_integer([:positive])}")
    OCILayout.build!(path, files, key, opts)
    path
  end

  describe "the import path's own checks (stand-in verifier)" do
    test "a valid layout is imported and its digests recorded", %{
      dir: dir,
      fake: fake,
      gguf: gguf
    } do
      files = [{"m.gguf", gguf}, {"LICENSE", "Apache-2.0\n"}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])

      assert {:ok, record} = import(dir, layout, fake)

      sha = Tier3Helper.sha256(gguf)
      assert record["weights_sha256"] == sha
      assert FakeOllama.blobs(fake.agent) == %{sha => gguf}

      assert [{"POST", "/api/create", %{"files" => %{"m.gguf" => "sha256:" <> ^sha}}}] =
               FakeOllama.requests(fake.agent, "/api/create")

      assert [%{"digest" => digest}] = Req.get!(fake.url <> "/api/tags").body["models"]

      assert record["ollama"] == %{
               "base_url" => fake.url,
               "model" => "embed-test:latest",
               "digest" => digest,
               "version" => "0.40.0"
             }

      assert record["files"] == %{
               "m.gguf" => sha,
               "LICENSE" => Tier3Helper.sha256("Apache-2.0\n")
             }

      assert record["model_info"]["pooling"] == "last" and record["model_info"]["dim"] == 8

      # The tokenizer is the one in the GGUF, under its own digest; the record is on disk.
      assert File.read!(record["tokenizer_path"]) |> Tier3Helper.sha256() ==
               record["tokenizer_sha256"]

      assert File.read!(record["tokenizer_path"]) ==
               Trinity.Memory.BPE.to_file(Tier3Helper.tokenizer())

      assert Jason.decode!(File.read!(record["record_path"]))["ollama"]["digest"] == digest

      # The staging directory is gone, and the configuration block names the pin.
      assert File.ls!(Path.join(dir, "staging")) == []
      block = Import.config_block(record, num_ctx: 512)
      assert block =~ ~s(digest: "#{digest}")
      assert block =~ "max_input_tokens: 511"
    end

    test "AC4 red: one flipped byte in the GGUF's blob is refused before anything reaches the service",
         %{dir: dir, fake: fake, gguf: gguf} do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])
      OCILayout.flip_layer!(layout, "m.gguf")

      assert import(dir, layout, fake) == {:error, {:blob_digest_mismatch, "m.gguf"}}
      assert FakeOllama.requests(fake.agent) == []
    end

    test "the OMS statement must list the GGUF that is imported", %{
      dir: dir,
      fake: fake,
      gguf: gguf
    } do
      other = Tier3Helper.gguf()
      layout = layout!(dir, [{"m.gguf", gguf}, {"model.sig", unsigned_oms([{"m.gguf", other}])}])
      assert import(dir, layout, fake) == {:error, {:oms_statement_mismatch, "m.gguf"}}

      layout = layout!(dir, [{"m.gguf", gguf}, {"model.sig", unsigned_oms([{"x.gguf", gguf}])}])
      assert import(dir, layout, fake) == {:error, {:oms_statement_lacks, "m.gguf"}}
    end

    test "titles must be plain file names, used once; one GGUF; the signature present",
         %{dir: dir, fake: fake, gguf: gguf} do
      sig = unsigned_oms([{"m.gguf", gguf}])

      assert import(dir, layout!(dir, [{"../m.gguf", gguf}, {"model.sig", sig}]), fake) ==
               {:error, {:layer_title_refused, "../m.gguf"}}

      assert import(dir, layout!(dir, [{"a/m.gguf", gguf}, {"model.sig", sig}]), fake) ==
               {:error, {:layer_title_refused, "a/m.gguf"}}

      assert import(
               dir,
               layout!(dir, [{"m.gguf", gguf}, {"m.gguf", gguf}, {"model.sig", sig}]),
               fake
             ) == {:error, {:layer_title_twice, "m.gguf"}}

      assert import(
               dir,
               layout!(dir, [{"a.gguf", gguf}, {"b.gguf", gguf}, {"model.sig", sig}]),
               fake
             ) == {:error, {:gguf_count, 2}}

      assert import(dir, layout!(dir, [{"m.gguf", gguf}]), fake) ==
               {:error, :oms_signature_missing}

      assert FakeOllama.requests(fake.agent) == []
    end

    test "a symbolic link in the layout is refused, not followed", %{
      dir: dir,
      fake: fake,
      gguf: gguf
    } do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])
      File.ln_s!("/etc/hostname", Path.join(layout, "extra"))
      assert {:error, {:layout_entry_refused, :symlink, _}} = import(dir, layout, fake)
    end

    test "the service must name the blob that was sent", %{dir: dir, fake: fake, gguf: gguf} do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])
      FakeOllama.set(fake.agent, :show_blob, String.duplicate("9", 64))

      assert import(dir, layout, fake) ==
               {:error, {:served_blob_mismatch, String.duplicate("9", 64)}}
    end

    test "a digest from the service that is not 64 hex characters is refused, not used as a file name",
         %{dir: dir, fake: fake, gguf: gguf} do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])
      FakeOllama.set(fake.agent, :create_digest, "../../escape")
      assert import(dir, layout, fake) == {:error, {:digest_refused, "../../escape"}}
      assert Path.wildcard(Path.join(dir, "**/*.import.json")) == []
    end

    test "a verifier's refusal ends the import", %{dir: dir, fake: fake, gguf: gguf} do
      defmodule RefuseCosign do
        @moduledoc false
        @behaviour Trinity.Memory.Tier3.Verifier
        @impl true
        def cosign(_l, _k, _o), do: {:error, {:cosign_refused, 1, "no"}}
        @impl true
        def oms(_d, _s, _k, _o), do: :ok
      end

      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])

      assert import(dir, layout, fake, verifier: RefuseCosign) ==
               {:error, {:cosign_refused, 1, "no"}}

      assert FakeOllama.requests(fake.agent) == []
    end

    test "the programs missing is a refusal, never a pass", %{dir: dir, fake: fake, gguf: gguf} do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])

      assert import(dir, layout, fake,
               verifier: Trinity.Memory.Tier3.Verifier.CLI,
               verifier_opts: [cosign: Path.join(dir, "no-cosign")]
             ) == {:error, {:program_missing, Path.join(dir, "no-cosign")}}
    end
  end

  describe "the CLI verifier and the mix task, with stand-in programs" do
    # Programs that only exit: the wrapper's contract is the exit status, and these hold it to
    # that on every leg. The real programs are the :signing_tools cases below.
    defp program!(dir, name, status, out) do
      path = Path.join(dir, name)
      File.write!(path, "#!/bin/sh\necho '#{out}'\nexit #{status}\n")
      File.chmod!(path, 0o755)
      path
    end

    test "exit 0 from both is a pass; the task prints the record and the configuration block",
         %{dir: dir, fake: fake, gguf: gguf} do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])

      argv = [
        "--layout",
        layout,
        "--cosign-key",
        "k.pub",
        "--oms-key",
        "o.pub",
        "--base-url",
        fake.url,
        "--model",
        "embed-test",
        "--out",
        Path.join(dir, "out"),
        "--cosign",
        program!(dir, "cosign-ok", 0, "verified"),
        "--model-signing",
        program!(dir, "oms-ok", 0, "Verification succeeded"),
        "--num-ctx",
        "512",
        "--query-prompt",
        "Q: "
      ]

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      Mix.Tasks.Trinity.Tier3.Import.run(argv)
      assert_received {:mix_shell, :info, [out]}
      assert out =~ "imported embed-test:latest: digest "
      assert out =~ "max_input_tokens: 511"
      assert out =~ ~s(query_prompt: "Q: ")
    end

    test "a non-zero exit is a refusal carrying the program's last lines", %{
      dir: dir,
      fake: fake,
      gguf: gguf
    } do
      files = [{"m.gguf", gguf}]
      layout = layout!(dir, files ++ [{"model.sig", unsigned_oms(files)}])
      bad = program!(dir, "cosign-bad", 1, "Error: no matching attestations")

      assert import(dir, layout, fake,
               verifier: Trinity.Memory.Tier3.Verifier.CLI,
               verifier_opts: [cosign: bad, model_signing: program!(dir, "oms-ok", 0, "ok")]
             ) == {:error, {:cosign_refused, 1, "Error: no matching attestations"}}

      assert import(dir, layout, fake,
               verifier: Trinity.Memory.Tier3.Verifier.CLI,
               verifier_opts: [
                 cosign: program!(dir, "cosign-ok", 0, "ok"),
                 model_signing: program!(dir, "oms-bad", 1, "Verification failed")
               ]
             ) == {:error, {:oms_refused, 1, "Verification failed"}}

      assert FakeOllama.requests(fake.agent) == []
    end

    test "the task refuses unknown options, a missing option, and a refusal, by raising", %{
      dir: dir
    } do
      assert_raise Mix.Error, ~r/unknown options/, fn ->
        Mix.Tasks.Trinity.Tier3.Import.run(["--nope", "x"])
      end

      assert_raise Mix.Error, ~r/refused: \{:option_missing, :layout\}/, fn ->
        Mix.Tasks.Trinity.Tier3.Import.run(["--out", dir])
      end
    end
  end

  describe "the real verifiers (:signing_tools)" do
    @describetag :signing_tools

    setup %{dir: dir} do
      tools = [
        cosign: System.fetch_env!("TRINITY_COSIGN"),
        model_signing: System.fetch_env!("TRINITY_MODEL_SIGNING")
      ]

      for {_, p} <- tools, do: assert(File.regular?(p), "#{p} is named and absent")

      cosign = OCILayout.key!()
      oms = OCILayout.key!()
      {cosign_pub, _} = OCILayout.write_key!(cosign, dir, "cosign")
      {oms_pub, oms_priv} = OCILayout.write_key!(oms, dir, "oms")

      {:ok,
       tools: tools, cosign: cosign, cosign_pub: cosign_pub, oms_pub: oms_pub, oms_priv: oms_priv}
    end

    # The model directory signed by model_signing itself: `[{name, bytes}]` plus model.sig.
    defp oms_signed!(ctx, files) do
      model = Path.join(ctx.dir, "model-#{System.unique_integer([:positive])}")
      File.mkdir_p!(model)
      for {n, b} <- files, do: File.write!(Path.join(model, n), b)
      sig = model <> ".sig"

      {out, status} =
        System.cmd(
          ctx.tools[:model_signing],
          ["sign", "key", "--private_key", ctx.oms_priv, "--signature", sig, model],
          stderr_to_stdout: true
        )

      assert status == 0, out
      files ++ [{"model.sig", File.read!(sig)}]
    end

    defp real(ctx, layout, extra \\ []) do
      import(
        ctx.dir,
        layout,
        ctx.fake,
        Keyword.merge(
          [
            cosign_key: ctx.cosign_pub,
            oms_key: ctx.oms_pub,
            verifier: Trinity.Memory.Tier3.Verifier.CLI,
            verifier_opts: ctx.tools
          ],
          extra
        )
      )
    end

    test "AC4: signed by both keys, verified offline, imported, and the digest recorded", ctx do
      layout = layout!(ctx.dir, oms_signed!(ctx, [{"m.gguf", ctx.gguf}]), ctx.cosign)
      assert {:ok, record} = real(ctx, layout)
      assert record["weights_sha256"] == Tier3Helper.sha256(ctx.gguf)
      assert record["cosign_key_sha256"] == Tier3Helper.sha256(File.read!(ctx.cosign_pub))
      assert record["oms_predicate_type"] == "https://model_signing/signature/v1.0"
      assert record["ollama"]["digest"] =~ ~r/\A[0-9a-f]{64}\z/

      IO.puts(
        "\nAC4: imported #{record["ollama"]["model"]}, digest #{record["ollama"]["digest"]}"
      )
    end

    test "AC4 red: one flipped bit in the cosign signature is refused by cosign", ctx do
      layout =
        layout!(ctx.dir, oms_signed!(ctx, [{"m.gguf", ctx.gguf}]), ctx.cosign,
          flip_signature: true
        )

      assert {:error, {:cosign_refused, 1, out}} = real(ctx, layout)
      assert out =~ "accepted signatures do not match threshold"
      assert FakeOllama.requests(ctx.fake.agent) == []
      IO.puts("\nAC4 red (cosign signature): #{out |> String.split("\n") |> List.last()}")
    end

    test "AC4 red: one flipped byte in the weights, repackaged and cosign-signed again, is refused by OMS",
         ctx do
      [{"m.gguf", _}, {"model.sig", sig}] = oms_signed!(ctx, [{"m.gguf", ctx.gguf}])
      tampered = OCILayout.flip(ctx.gguf, byte_size(ctx.gguf) - 10)
      layout = layout!(ctx.dir, [{"m.gguf", tampered}, {"model.sig", sig}], ctx.cosign)
      assert {:error, {:oms_refused, 1, out}} = real(ctx, layout)
      assert out =~ "m.gguf"
      assert FakeOllama.requests(ctx.fake.agent) == []

      IO.puts(
        "\nAC4 red (weights, cosign valid): #{out |> String.split("\n") |> List.last() |> String.slice(0, 120)}"
      )
    end

    test "AC4 red: one flipped byte in the OMS signature, repackaged and cosign-signed again, is refused by OMS",
         ctx do
      [{"m.gguf", g}, {"model.sig", sig}] = oms_signed!(ctx, [{"m.gguf", ctx.gguf}])
      bundle = Jason.decode!(sig)
      raw = bundle["dsseEnvelope"]["signatures"] |> hd() |> Map.fetch!("sig") |> Base.decode64!()

      flipped =
        put_in(bundle, ["dsseEnvelope", "signatures"], [
          %{"sig" => Base.encode64(OCILayout.flip(raw, 10))}
        ])

      layout =
        layout!(ctx.dir, [{"m.gguf", g}, {"model.sig", Jason.encode!(flipped)}], ctx.cosign)

      assert {:error, {:oms_refused, 1, _}} = real(ctx, layout)
      assert FakeOllama.requests(ctx.fake.agent) == []
    end

    test "another operator's keys are refused, each by its own verifier", ctx do
      layout = layout!(ctx.dir, oms_signed!(ctx, [{"m.gguf", ctx.gguf}]), ctx.cosign)
      {other_pub, _} = OCILayout.write_key!(OCILayout.key!(), ctx.dir, "other")
      assert {:error, {:cosign_refused, 1, _}} = real(ctx, layout, cosign_key: other_pub)
      assert {:error, {:oms_refused, 1, _}} = real(ctx, layout, oms_key: other_pub)
    end

    test "a valid cosign signature over another artifact does not vouch for this one", ctx do
      files = oms_signed!(ctx, [{"m.gguf", ctx.gguf}])
      other = layout!(ctx.dir, [{"x.gguf", "other"}], nil)

      other_digest =
        Jason.decode!(File.read!(Path.join(other, "index.json")))["manifests"]
        |> hd()
        |> Map.fetch!("digest")

      layout = layout!(ctx.dir, files, ctx.cosign, sign_digest: other_digest)
      assert {:error, {:cosign_refused, 1, _}} = real(ctx, layout)
    end

    test "an unsigned layout is refused by cosign", ctx do
      layout = layout!(ctx.dir, oms_signed!(ctx, [{"m.gguf", ctx.gguf}]), nil)
      assert {:error, {:cosign_refused, 1, out}} = real(ctx, layout)
      assert out =~ "no signatures"
    end
  end
end
