# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.EmbedderBootNodeTest do
  @moduledoc """
  Slice 133, AC5 and AC6's second half, where they are real: a boot, in a separate OS process.

  AC5: under `:regulated` each embedder configuration fault refuses the boot with its own named
  error (an endpoint off `TRINITY_REGULATED_LLM_ENDPOINTS`, an embedder with no `locality:`, an
  `:external` embedder without the operator's opt-in), and a correct one boots. A `localhost`
  URL with no `locality:` is a fault under **both** profiles: under `:default` the node boots and
  semantic memory is OFF with the same reason, which is what "fails config validation" means
  where the profile never refuses a boot.

  AC6: one corrupted byte in the static weights turns semantic memory OFF with
  `:weights_digest_mismatch` and the application still boots. Here on a synthetic artifact (the
  real format, no model), so it runs on every leg; `:static_weights` repeats it on the real file.

  The harness is `Trinity.RegulatedBootNodeTest`'s: `MIX_ENV=test`, `XDG_DATA_HOME` and
  databases per case (`Trinity.BootIsolation`), the child printing `BOOT_OK` or `BOOT_REFUSED`
  with the reason at `limit: :infinity`, and assertions on that one line only.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  """

  # After a boot that succeeded: the tier's status, from inside the node.
  @report """
  case Application.ensure_all_started(:trinity) do
    {:ok, _} ->
      IO.puts("BOOT_OK")
      IO.puts("SEMANTIC " <> inspect(Trinity.Memory.Semantic.status(), limit: :infinity))
      System.halt(0)

    {:error, reason} ->
      IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
      System.halt(3)
  end
  """

  @fixture """
  defmodule EmbedderBootFixture do
    @behaviour Trinity.Authority
    def stage(staged, _ctx), do: {:ok, staged}
    def decide(_staged, decision, _ctx), do: {:ok, decision, "fixture"}
    def execute(_staged, _decision, _ctx), do: {:error, :not_used}
    def receipt(_kind, _attrs), do: {:error, :not_used}
  end
  Application.put_env(:trinity, :mcp_auth, profile: :production)
  """

  # The chat model on the allow-list, and an embedding model at `url`; then the memory config.
  defp models_and_memory(url, memory) do
    """
    llm = Application.get_env(:trinity, :llm, [])
    Application.put_env(:trinity, :llm, Keyword.put(llm, :models, [
      %{id: "allowed", provider: :req_llm, model: "openai:x",
        base_url: "https://models.internal/v1", api_key_env: "NONE",
        caps: [:stream], price: %{input: 0.0, output: 0.0}},
      %{id: "embedder", provider: :req_llm, model: "openai_compatible:e5",
        base_url: #{inspect(url)}, api_key_env: "NONE",
        caps: [:embed], price: %{input: 0.0, output: 0.0}}
    ]))
    memory = Application.get_env(:trinity, :memory, [])
    Application.put_env(:trinity, :memory, Keyword.merge(memory, #{inspect(memory)}))
    """
  end

  defp case_setup(name) do
    tag = Trinity.BootIsolation.tag(name)
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    dir = Path.join(System.tmp_dir!(), "embboot-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, tag}
  end

  defp boot(name, env, script) do
    {root, tag} = case_setup(name)

    base = [
      {"MIX_ENV", "test"},
      {"XDG_DATA_HOME", root},
      {"TRINITY_BOOT_TAG", tag},
      {"TRINITY_PROFILE", nil},
      {"TRINITY_AUTHORITY", nil},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", nil},
      {"TRINITY_MCP_AUTH_PROFILE", nil},
      {"TRINITY_STATIC_MODEL_DIR", nil}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", @isolate <> script],
      env: base ++ env,
      stderr_to_stdout: true
    )
  end

  defp regulated(extra \\ []) do
    [
      {"TRINITY_PROFILE", "regulated"},
      {"TRINITY_AUTHORITY", "EmbedderBootFixture"},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
    ] ++ extra
  end

  defp line(out, prefix),
    do: out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, prefix))

  defp refused!(out, status, reason) do
    assert status == 3, "the node started:\n#{String.slice(out, -3000, 3000)}"
    refusal = line(out, "BOOT_REFUSED")

    assert refusal =~ reason,
           "it refused, but the printed reason is not the one under test:\n#{refusal}"

    IO.puts("\n" <> refusal)
    refusal
  end

  describe "AC5: config faults refuse a regulated boot, each with its name" do
    test "a within_boundary endpoint not on the allow-list: :not_allow_listed" do
      script =
        @fixture <>
          models_and_memory("https://embed.internal/v1",
            embedder: :hosted,
            hosted_model: "embedder",
            locality: :within_boundary
          ) <> @report

      {out, status} = boot("emb_not_listed", regulated(), script)
      refusal = refused!(out, status, "not_allow_listed")
      assert refusal =~ "https://embed.internal"
    end

    test "an embedder with an endpoint and no locality: :embedder_locality_undeclared" do
      script =
        @fixture <>
          models_and_memory("https://models.internal/v1",
            embedder: :hosted,
            hosted_model: "embedder"
          ) <> @report

      {out, status} = boot("emb_no_locality", regulated(), script)
      refused!(out, status, "embedder_locality_undeclared")
    end

    test "an external embedder without the operator's opt-in: :external_not_opted_in" do
      script =
        @fixture <>
          models_and_memory("https://models.internal/v1",
            embedder: :hosted,
            hosted_model: "embedder",
            locality: :external
          ) <> @report

      {out, status} = boot("emb_external", regulated(), script)
      refused!(out, status, "external_not_opted_in")
    end

    test "the correct configuration boots: within_boundary on the allow-list, and external with the opt-in" do
      for {name, memory} <- [
            {"emb_good_within",
             [embedder: :hosted, hosted_model: "embedder", locality: :within_boundary]},
            {"emb_good_external",
             [
               embedder: :hosted,
               hosted_model: "embedder",
               locality: :external,
               external_opt_in: true
             ]}
          ] do
        script = @fixture <> models_and_memory("https://models.internal/v1", memory) <> @report
        {out, status} = boot(name, regulated(), script)

        assert status == 0, """
        a correctly configured regulated node refused (#{name}): if this fails while the refusals
        pass, the check refuses everything and proves nothing.
        #{String.slice(out, -3000, 3000)}
        """

        assert line(out, "BOOT_OK") == "BOOT_OK"
      end
    end
  end

  describe "AC5: locality is never inferred from an address, under both profiles" do
    test "a localhost URL with no locality refuses a regulated boot" do
      script =
        @fixture <>
          models_and_memory("http://localhost:11434/v1",
            embedder: :hosted,
            hosted_model: "embedder"
          ) <> @report

      {out, status} =
        boot(
          "emb_localhost_reg",
          regulated([
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal,http://localhost"}
          ]),
          script
        )

      refusal = refused!(out, status, "embedder_locality_undeclared")
      assert refusal =~ "http://localhost:11434/v1"
    end

    test "a localhost URL with no locality fails validation under default: it boots with semantic memory OFF and the same reason" do
      script =
        models_and_memory("http://localhost:11434/v1",
          embedder: :hosted,
          hosted_model: "embedder"
        ) <> @report

      {out, status} = boot("emb_localhost_def", [], script)
      assert status == 0, String.slice(out, -3000, 3000)
      assert line(out, "BOOT_OK") == "BOOT_OK"

      IO.puts("\n" <> line(out, "SEMANTIC"))

      assert line(out, "SEMANTIC") =~
               ~s(SEMANTIC {:off, {:config, {:embedder_locality_undeclared, :hosted, "http://localhost:11434/v1"}}})
    end
  end

  describe "AC6: a corrupted byte in the weights" do
    test "turns semantic memory OFF with :weights_digest_mismatch, and the application still boots" do
      {root, _} = case_setup("weights_src")
      digest = Trinity.StaticWeights.synthetic!(root)
      file = Path.join(root, Trinity.Memory.Embedders.Static.file_name("256-int8"))

      memory =
        "[embedder: :static, static_dir: #{inspect(root)}, static_sha256: #{inspect(digest)}]"

      script = """
      memory = Application.get_env(:trinity, :memory, [])
      Application.put_env(:trinity, :memory, Keyword.merge(memory, #{memory}))
      #{@report}
      """

      # The good file first: the same configuration is on, so the corruption is the only change.
      {out, 0} = boot("weights_good", [], script)
      assert line(out, "SEMANTIC") == "SEMANTIC :on"

      bin = File.read!(file)
      at = div(byte_size(bin), 2)
      <<head::binary-size(^at), byte, tail::binary>> = bin
      File.write!(file, <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>)

      {out, status} = boot("weights_bad", [], script)
      assert status == 0, String.slice(out, -3000, 3000)
      assert line(out, "BOOT_OK") == "BOOT_OK"
      IO.puts("\n" <> line(out, "SEMANTIC"))
      assert line(out, "SEMANTIC") == "SEMANTIC {:off, :weights_digest_mismatch}"
    end

    @tag :static_weights
    test "on the real artifact: one flipped byte, OFF with :weights_digest_mismatch, still boots" do
      {root, _} = case_setup("weights_real")
      name = Trinity.Memory.Embedders.Static.file_name("256-int8")
      File.cp!(Trinity.StaticWeights.file!(name), Path.join(root, name))
      bin = File.read!(Path.join(root, name))
      at = div(byte_size(bin), 3)
      <<head::binary-size(^at), byte, tail::binary>> = bin
      File.write!(Path.join(root, name), <<head::binary, Bitwise.bxor(byte, 0x80), tail::binary>>)

      script = """
      memory = Application.get_env(:trinity, :memory, [])
      Application.put_env(:trinity, :memory, Keyword.merge(memory, [embedder: :static, static_dir: #{inspect(root)}]))
      #{@report}
      """

      {out, status} = boot("weights_real_bad", [], script)
      assert status == 0, String.slice(out, -3000, 3000)
      assert line(out, "SEMANTIC") == "SEMANTIC {:off, :weights_digest_mismatch}"
    end
  end
end
