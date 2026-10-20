# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ToolchainNodeTest do
  @moduledoc """
  Slice 137 at the only place its refusals are real: a boot, in a separate OS process.

  The recipe is `Trinity.RegulatedBootNodeTest`'s: `XDG_DATA_HOME` and `Trinity.BootIsolation` per
  case, `MIX_ENV=test` so the child reuses the built test tree, `mix run --no-start`, and every
  assertion on the one line the child prints, never on the whole captured output.

  ## The below-floor runtime

  AC2 needs an Erlang runtime that carries CVE-2026-55737. None ships with this tree, so the case
  is tagged `:below_floor_otp` and runs where `TRINITY_BELOW_FLOOR_OTP` names the `bin` directory
  of one: OTP 28.1.1 on a developer machine, OTP 28.5.0.3 in the CI job built for it. Where the
  variable is set, a directory with no `erl` in it is a failure, not a skip.

  The child is the same compiled tree run on the older runtime, which is what a release copied
  onto an older ERTS would be. Measured before this file was written: code compiled on OTP
  28.5.0.6 loads and runs on erts 16.1.1 (OTP 28.1.1), Elixir 1.20.4 and `crypto` included.

  ## The headless release's floor (slice 141)

  The headless release is held to OTP 28.5.0.8 on the OTP 28 line only. Two cases show it:

  * one untagged, on this suite's own runtime, whose expectation comes from that runtime's
    `OTP_VERSION` file, read here and not by `Trinity.Toolchain`. The gate's 28.5.0.6 refuses a
    headless node; the FIPS image's 28.5.0.8 boots one. Each run prints which it was;
  * one tagged `:below_headless_floor_otp`, where `TRINITY_BELOW_HEADLESS_FLOOR_OTP` names the `bin`
    of OTP 28.5.0.7, the release before the floor. The refusal names erts and every application
    below the row, and the same runtime boots a desktop node, so the two floors are told apart on
    one runtime.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  """

  @report """
  case Application.ensure_all_started(:trinity) do
    {:ok, _} ->
      IO.puts("BOOT_OK")
      System.halt(0)

    {:error, reason} ->
      IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
      System.halt(3)
  end
  """

  # The tail for a node expected to boot with ML-DSA-87 receipts. Booting is not enough: the boot
  # receipt is signed afterwards by a transient task (`Trinity.Effects.Boot`), so a key that
  # cannot sign would still print BOOT_OK. This waits for the receipt and prints its scheme and the
  # offline verifier's answer over the exported chain.
  @report_signed """
  case Application.ensure_all_started(:trinity) do
    {:ok, _} ->
      IO.puts("BOOT_OK")

      receipt =
        Enum.find_value(1..50, fn _ ->
          Trinity.Receipts.boot_receipt() || (Process.sleep(100) && nil)
        end)

      IO.puts("SIGNED " <> ((receipt && receipt.scheme) || "none"))
      {:ok, export} = Trinity.Receipts.export("boot")
      IO.puts("VERIFY " <> inspect(Trinity.Receipts.Verifier.verify(export |> JSON.encode!() |> JSON.decode!())))
      System.halt(0)

    {:error, reason} ->
      IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
      System.halt(3)
  end
  """

  @fixture """
  defmodule ToolchainBootFixture do
    @behaviour Trinity.Authority
    def stage(staged, _ctx), do: {:ok, staged}
    def decide(_staged, decision, _ctx), do: {:ok, decision, "fixture"}
    def execute(_staged, _decision, _ctx), do: {:error, :not_used}
    def receipt(_kind, _attrs), do: {:error, :not_used}
  end
  """

  @regulated_config """
  Application.put_env(:trinity, :mcp_auth, profile: :production)
  llm = Application.get_env(:trinity, :llm, [])
  Application.put_env(:trinity, :llm, Keyword.put(llm, :models, [
    %{id: "allowed", provider: :req_llm, model: "openai:x",
      base_url: "https://models.internal/v1", api_key_env: "NONE",
      caps: [:stream], price: %{input: 0.0, output: 0.0}}
  ]))
  """

  @mldsa87_receipts """
  r = Application.get_env(:trinity, :receipts, [])
  Application.put_env(:trinity, :receipts, Keyword.put(r, :algorithm, :mldsa87))
  """

  defp case_setup(name) do
    tag = Trinity.BootIsolation.tag(name)
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    dir = Path.join(System.tmp_dir!(), "toolchain-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, tag}
  end

  defp boot(env, script) do
    base = [
      {"MIX_ENV", "test"},
      {"TRINITY_PROFILE", nil},
      {"TRINITY_AUTHORITY", nil},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", nil},
      {"TRINITY_REGULATED_EGRESS", "docs.internal"},
      {"TRINITY_MCP_AUTH_PROFILE", nil}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", @isolate <> script],
      env: base ++ env,
      stderr_to_stdout: true
    )
  end

  defp refusal_line(out) do
    out
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "BOOT_REFUSED"))
  end

  # The refusal line with the quotes of the reason unescaped: the reason is printed inside the
  # inspected RuntimeError message, so its strings arrive as \"...\".
  defp refusal(out), do: out |> refusal_line() |> String.replace(~S(\"), ~S("))

  # The OTP release of the VM running this suite, from the `OTP_VERSION` file a full installation
  # carries. An assembled release has none (slice 130, D-130-11), which is why `Trinity.Toolchain`
  # reads application versions instead; that makes this an oracle independent of the code under
  # test, not a copy of it.
  defp this_otp do
    major = List.to_string(:erlang.system_info(:otp_release))

    [:code.root_dir(), "releases", major, "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  defp version_list(v), do: v |> String.split(".") |> Enum.map(&String.to_integer/1)

  # The erts version and OTP major of the runtime in `bin`, asked of that runtime itself.
  defp runtime_of(bin) do
    {out, 0} =
      System.cmd(
        Path.join(bin, "erl"),
        [
          "-noshell",
          "-eval",
          ~s|io:format("~s ~s", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().|
        ]
      )

    [major, erts] = String.split(String.trim(out), " ")
    {major, erts}
  end

  describe "AC2: a runtime below the floor refuses before any child starts" do
    @describetag :below_floor_otp

    test "the line the child prints names the refusal, the runtime's erts and the floor" do
      bin = System.fetch_env!("TRINITY_BELOW_FLOOR_OTP")

      assert File.exists?(Path.join(bin, "erl")),
             "TRINITY_BELOW_FLOOR_OTP=#{bin} has no erl; a missing runtime is a failure here"

      {major, erts} = runtime_of(bin)
      floor = %{"27" => "15.2.7.11", "28" => "16.4.0.4", "29" => "17.0.4"}

      assert Map.has_key?(floor, major),
             "the below-floor runtime is OTP #{major}, which has no row to compare against"

      {root, tag} = case_setup("below-floor")

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"PATH", bin <> ":" <> System.get_env("PATH")}
          ],
          @report
        )

      line = refusal_line(out)

      assert status == 3,
             """
             a node on OTP #{major} (erts #{erts}) did not refuse to boot; that runtime carries \
             CVE-2026-55737, fixed in erts #{floor[major]}.

             #{String.slice(out, -3000, 3000)}
             """

      assert line =~ "otp_below_floor", line
      assert line =~ erts, line
      assert line =~ floor[major], line
    end

    # Slice 141. The version comparison refuses first at boot, so the probe's own answer on a
    # runtime that carries the defect is asked for directly.
    test "slice 141: the decoder probe finds the defect itself on that runtime" do
      bin = System.fetch_env!("TRINITY_BELOW_FLOOR_OTP")

      {out, 0} =
        System.cmd(
          "mix",
          [
            "run",
            "--no-start",
            "-e",
            ~s|IO.puts("DECODER " <> inspect(Trinity.Toolchain.check_decoder()))|
          ],
          env: [{"MIX_ENV", "test"}, {"PATH", bin <> ":" <> System.get_env("PATH")}],
          stderr_to_stdout: true
        )

      line = out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "DECODER"))
      assert line == "DECODER {:error, {:decoder_accepts_oversize_tuple, 16777216}}", out
    end
  end

  describe "slice 141: the decoder is asked at boot" do
    # No runtime reports a fixed version over an unfixed decoder, so the seam plants one. A tree
    # whose boot skipped the probe ignores the seam and boots, which is this test's red.
    test "a node whose decoder accepts the oversize tuple refuses, naming it" do
      {root, tag} = case_setup("decoder-planted")

      {out, status} =
        boot(
          [{"XDG_DATA_HOME", root}, {"TRINITY_BOOT_TAG", tag}],
          "Application.put_env(:trinity, :decoder_probe_fault, true)\n" <> @report
        )

      assert status == 3,
             "a node with a planted decoder booted:\n" <> String.slice(out, -3000, 3000)

      assert refusal(out) =~ "{:decoder_accepts_oversize_tuple, 16777216}", refusal(out)
    end
  end

  describe "slice 141: the headless release refuses below OTP 28.5.0.8" do
    test "a headless node on this suite's runtime boots only at 28.5.0.8 or later on OTP 28" do
      otp = this_otp()
      [major | _] = version_list(otp)
      at_floor? = major == 28 and version_list(otp) >= [28, 5, 0, 8]

      IO.puts(
        "toolchain_node_test: OTP #{otp}, so a headless node " <>
          if(at_floor?, do: "boots", else: "refuses")
      )

      for {name, env} <- [
            {"headless-mode", [{"TRINITY_MODE", "headless"}]},
            {"headless-release", [{"RELEASE_NAME", "headless"}]}
          ] do
        {root, tag} = case_setup(name)

        {out, status} =
          boot([{"XDG_DATA_HOME", root}, {"TRINITY_BOOT_TAG", tag} | env], @report)

        if at_floor? do
          assert status == 0, "#{name}: " <> String.slice(out, -3000, 3000)
          assert out =~ "BOOT_OK"
        else
          line = refusal(out)
          assert status == 3, "#{name} on OTP #{otp} booted:\n" <> String.slice(out, -3000, 3000)

          if major == 28 do
            assert line =~ "{:otp_below_floor, 28, \"28.5.0.8\"", line
          else
            assert line =~ "otp_major_unsupported", line
          end
        end
      end
    end

    @tag :below_headless_floor_otp
    test "OTP 28.5.0.7 refuses a headless node, naming erts and ssl, and boots a desktop one" do
      bin = System.fetch_env!("TRINITY_BELOW_HEADLESS_FLOOR_OTP")

      assert File.exists?(Path.join(bin, "erl")),
             "TRINITY_BELOW_HEADLESS_FLOOR_OTP=#{bin} has no erl; a missing runtime is a failure here"

      assert {"28", "16.4.0.6"} = runtime_of(bin)
      path = {"PATH", bin <> ":" <> System.get_env("PATH")}

      {root, tag} = case_setup("below-headless-floor")

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_MODE", "headless"},
            path
          ],
          @report
        )

      line = refusal(out)

      assert status == 3,
             "a headless node on OTP 28.5.0.7 booted:\n" <> String.slice(out, -3000, 3000)

      assert line =~ "{:otp_below_floor, 28, \"28.5.0.8\"", line
      assert line =~ ~s|{:ssl, "11.6.0.6", "11.6.0.7"}|, line
      assert line =~ ~s|{:erts, "16.4.0.6", "16.4.0.7"}|, line

      {root, tag} = case_setup("below-headless-floor-desktop")
      {out, status} = boot([{"XDG_DATA_HOME", root}, {"TRINITY_BOOT_TAG", tag}, path], @report)
      assert status == 0, "a desktop node on OTP 28.5.0.7: " <> String.slice(out, -3000, 3000)
      assert out =~ "BOOT_OK"
    end
  end

  describe "AC3: the pinned runtime boots, so the refusal can be met" do
    test "a default node boots" do
      {root, tag} = case_setup("pinned-default")
      {out, status} = boot([{"XDG_DATA_HOME", root}, {"TRINITY_BOOT_TAG", tag}], @report)
      assert status == 0, String.slice(out, -3000, 3000)
      assert out =~ "BOOT_OK"
    end

    test "a regulated node with every condition met boots" do
      {root, tag} = case_setup("pinned-regulated")

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "ToolchainBootFixture"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
          ],
          @fixture <> @regulated_config <> @report
        )

      assert status == 0, String.slice(out, -4000, 4000)
      assert out =~ "BOOT_OK"
    end
  end

  describe "AC7: a regulated node configured to sign with ML-DSA-87 refuses when it cannot" do
    # Through the path that already exists: `KeyCustody.select/0` answers an error, and
    # `Profile.check_receipts/2` refuses a regulated boot on it. What this slice adds is that the
    # answer comes from the known-answer preflight and names the step that failed.
    defp regulated_mldsa87(name, planted, tail \\ @report) do
      {root, tag} = case_setup(name)

      fault =
        if planted,
          do: "Application.put_env(:trinity, :mldsa87_preflight_fault, #{inspect(planted)})\n",
          else: ""

      boot(
        [
          {"XDG_DATA_HOME", root},
          {"TRINITY_BOOT_TAG", tag},
          {"TRINITY_PROFILE", "regulated"},
          {"TRINITY_AUTHORITY", "ToolchainBootFixture"},
          {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
        ],
        @fixture <> @regulated_config <> @mldsa87_receipts <> fault <> tail
      )
    end

    # Only where the runtime signs ML-DSA-87: elsewhere the check fails at :keygen before a fault
    # planted later can be observed. `test/test_helper.exs` derives the tag from the oracle.
    @tag :mldsa87_runtime
    test "a failing preflight refuses the boot, naming the step" do
      # The seam plants a failure at one step. A tree without the preflight ignores the key and
      # boots, which is this test's red.
      {out, status} = regulated_mldsa87("mldsa87-preflight-fails", :verify)
      line = refusal_line(out)

      assert status == 3,
             """
             a regulated node configured to sign receipts with ML-DSA-87 booted although the \
             known-answer check failed at :verify.

             #{String.slice(out, -3000, 3000)}
             """

      assert line =~ "mldsa87_preflight_failed", line
      assert line =~ ":verify", line
    end

    # With no fault planted the answer is the runtime's own, and the expectation comes from an
    # oracle here, not from the code under test: ML-DSA-87 tried directly through `:crypto`. It
    # signs only where the linked OpenSSL is 3.5 or later with the mode off (the FIPS image with
    # the mode off). It does not on a host linked to OpenSSL 3.0, measured on hacktuah 2026-10-19
    # (`{:no_approved_signer, :mldsa87, :not_supported}`), nor in the mode on Red Hat's provider
    # (slice 003). The child inherits this VM's runtime and mode, so the oracle answers for it.
    test "with no fault planted, the runtime's own answer decides" do
      {out, status} = regulated_mldsa87("mldsa87-preflight-unplanted", nil, @report_signed)

      if Trinity.TestSupport.MLDSA87Oracle.signs?() do
        assert status == 0, String.slice(out, -3000, 3000)
        assert out =~ "BOOT_OK"

        # The boot receipt was signed with the ML-DSA-87 key this boot made, and the chain verifies
        # offline: the path F-137-2 broke, end to end.
        assert [_, scheme] = Regex.run(~r/^SIGNED (\S+)$/m, out), out
        assert scheme =~ "mldsa87", out
        assert out =~ ~r/^VERIFY \{:ok, /m, out
      else
        assert status == 3, String.slice(out, -3000, 3000)
        assert refusal_line(out) =~ "mldsa87_preflight_failed", refusal_line(out)
      end
    end
  end

  describe "the default profile stays fail-open over the signer" do
    # Rule 1 of the regulated-boot slice: under :default a signer that cannot sign sets the alarm
    # and the node starts with every effect denied. This slice must not change that.
    test "a failing ML-DSA-87 preflight does not stop a default node" do
      {root, tag} = case_setup("mldsa87-default-fail-open")

      script =
        @mldsa87_receipts <>
          "Application.put_env(:trinity, :mldsa87_preflight_fault, :sign)\n" <> @report

      {out, status} = boot([{"XDG_DATA_HOME", root}, {"TRINITY_BOOT_TAG", tag}], script)
      assert status == 0, String.slice(out, -3000, 3000)
      assert out =~ "BOOT_OK"
    end
  end
end
