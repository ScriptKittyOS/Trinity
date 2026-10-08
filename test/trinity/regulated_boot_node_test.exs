# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.RegulatedBootNodeTest do
  @moduledoc """
  AC1 to AC5 at the only place they are real: a boot.

  `Trinity.ProfileTest` proves the decisions. It does not prove the boot, and a suite that proves
  `Profile.check_*` and calls that AC1 to AC5 is proving the easy half. `start/2` cannot be re-run
  in this VM, where the application is already up, so each case here spawns a **separate OS
  process** with its own environment and asserts on what that process did.

  ## How each case is isolated

  `XDG_DATA_HOME` per case, which `Trinity.Paths.data_dir/2` reads on Linux, so the child gets its
  own data directory, its own `Trinity.DataDir.Lock` and its own database files and cannot collide
  with this suite or with another case.

  `MIX_ENV=test`, so the child reuses the test tree that is already built everywhere and reaches no
  network. This was `MIX_ENV=dev`, which meant the child compiled the whole dev dependency tree
  from scratch. That cost nothing on a developer machine with a warm `_build`, and on CI it cost
  everything: on the FIPS leg the compile could not finish at all, because fetching the
  `tokenizers` NIF needs a TLS handshake OTP cannot complete (erlang/otp#8470), and on the `gate`
  leg it merely took too long, until a loaded runner pushed one case past its 180 s timeout. The
  dev compile was the defect; the FIPS leg was only where it failed loudly.

  `Trinity.BootIsolation` gives each child its own databases. That is the problem `MIX_ENV=test`
  brings with it and the reason it was rejected once: `config/test.exs` fixes the database and does
  not derive it from `XDG_DATA_HOME`, so without this the six children would write into the suite's
  own chain. Measured before the helper existed, a child appended its boot receipt at `seq 360` on
  the live chain. The helper rewrites both repos' configuration in whichever shape the compiled
  adapter uses, creates the storage, runs the migrations the child would otherwise skip, and drops
  the sandbox pool, since a child is a real boot and owns no sandbox connection.

  Nothing here touches `:persistent_term` in this VM. Every mutation happens in the child.

  ## Every leg runs all six cases

  There is no longer a leg this file skips. It carried `:needs_dev_compile`, excluded where
  `TRINITY_FIPS_LEG=1`, for as long as the child needed a dev build; that tag and its exclusion are
  gone with the dev compile that caused them.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  # Prepended to every child script, ahead of the case's own setup: its databases exist and are
  # migrated before the application is asked to start.
  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  """

  # A signer failure the child can reproduce, on whichever algorithm the leg selects.
  #
  # The key is `receipts-<algorithm>.key` (`KeyCustody.key_path/2`) and the algorithm is `:p384`
  # whenever `:crypto.info_fips()` is `:enabled`, else `:ed25519` (`KeyCustody.select/0`). This used
  # to sabotage the ed25519 name alone, so on the FIPS leg it aimed at a file the signer never
  # opens: the node generated a p384 key, booted, and case 6 failed on a correct assertion while
  # case 1 passed for the wrong reason. Every candidate name is taken instead.
  #
  # Each is a **directory**, which is deliberate and not interchangeable with the simpler sabotage
  # of making `keys_dir` itself a file. A directory where the key belongs gives `File.read/1`
  # `{:error, :eisdir}`, which `KeyCustody` returns as `{:error, {:key_file, :eisdir}}` — an error
  # tuple, on the path the receipts supervisor is fail-open over. A `keys_dir` that is a regular
  # file instead makes `File.mkdir_p!/1` **raise** `%File.Error{reason: :enotdir}`, which takes the
  # boot down under `:default` too and so cannot express "the signer is down and a default node
  # still starts". Measured, not reasoned: that is filed as its own finding.
  defp broken_keys_dir(root) do
    dir = Path.join(root, "broken-keys")

    for algorithm <- ["ed25519", "p384", "mldsa87"] do
      File.mkdir_p!(Path.join(dir, "receipts-#{algorithm}.key"))
    end

    dir
  end

  # A case's own data directory and its own database name, with the databases dropped afterwards.
  # The drop matters under Postgres, where a leaked database outlives the run.
  defp case_setup(name) do
    tag = Trinity.BootIsolation.tag(name)
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    {tmp!(name), tag}
  end

  defp tmp!(name) do
    dir = Path.join(System.tmp_dir!(), "regboot-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # One child boot. Returns `{output, exit_status}`; the script prints BOOT_OK or BOOT_REFUSED and
  # halts, so the status distinguishes the two without parsing prose.
  defp boot(env, script) do
    base = [
      {"MIX_ENV", "test"},
      # Never inherit this suite's values for anything the code under test reads.
      {"TRINITY_PROFILE", nil},
      {"TRINITY_AUTHORITY", nil},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", nil},
      # Slice 135: a regulated node with the default `network: :allow` needs an egress
      # allow-list. Every case here has one, so each refuses (or boots) for the reason it names;
      # the refusal without one is `Trinity.SecretsBootNodeTest`'s AC5.
      {"TRINITY_REGULATED_EGRESS", "docs.internal"},
      {"TRINITY_MCP_AUTH_PROFILE", nil}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", @isolate <> script],
      env: base ++ env,
      stderr_to_stdout: true
    )
  end

  # The tail of every script: start the application and say what happened.
  #
  # `limit: :infinity` is not decoration. This was `limit: 3`, which printed
  # `BOOT_REFUSED {:trinity, {{...}, ...}}` and hid the reason entirely, so an assertion that the
  # reason was named passed only because the same words appear in the crash report OTP writes to
  # stderr. A test for "it refused, and said why" has to read what the node said.
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

  # The line the child printed, and nothing else: not the crash report, not a log line. Every
  # refusing case asserts through this, so a reason that reaches stderr but never reaches the line
  # the node printed fails the test rather than passing it.
  defp refusal_line(out) do
    out
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "BOOT_REFUSED"))
  end

  # A module that implements Trinity.Authority and is not Local. Defined in the child rather than
  # added to lib/, because AC5 says no adapter is supplied by this tree and none is invented.
  @fixture """
  defmodule RegulatedBootFixture do
    @behaviour Trinity.Authority
    def stage(staged, _ctx), do: {:ok, staged}
    def decide(_staged, decision, _ctx), do: {:ok, decision, "fixture"}
    def execute(_staged, _decision, _ctx), do: {:error, :not_used}
    def receipt(_kind, _attrs), do: {:error, :not_used}
  end
  """

  defp production_mcp_auth do
    """
    Application.put_env(:trinity, :mcp_auth, profile: :production)
    """
  end

  defp allowed_models do
    """
    llm = Application.get_env(:trinity, :llm, [])
    Application.put_env(:trinity, :llm, Keyword.put(llm, :models, [
      %{id: "allowed", provider: :req_llm, model: "openai:x",
        base_url: "https://models.internal/v1", api_key_env: "NONE",
        caps: [:stream], price: %{input: 0.0, output: 0.0}}
    ]))
    """
  end

  describe "1. the default profile boots with the signer down" do
    test "a broken key store does not stop a default node" do
      {root, tag} = case_setup("default-signer-down")

      script = """
      r = Application.get_env(:trinity, :receipts, [])
      Application.put_env(:trinity, :receipts, Keyword.put(r, :keys_dir, "#{broken_keys_dir(root)}"))
      #{@report}
      """

      {out, status} = boot([{"XDG_DATA_HOME", root}, {"TRINITY_BOOT_TAG", tag}], script)

      assert status == 0,
             """
             the default profile refused to boot with the signer down. That is rule 1: \
             lib/trinity/receipts/supervisor.ex is fail-open for every profile that is not \
             :regulated, and this is the test that says so.

             #{String.slice(out, -3000, 3000)}
             """

      assert out =~ "BOOT_OK"
    end
  end

  describe "2. regulated refuses an unset endpoint allow-list" do
    test "production mcp_auth and a non-Local authority, but no allow-list, does not start" do
      {root, tag} = case_setup("regulated-no-endpoints")

      script = """
      #{@fixture}
      #{production_mcp_auth()}
      #{@report}
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "RegulatedBootFixture"}
          ],
          script
        )

      assert status == 3, "the node started with no endpoint allow-list:\n#{out}"
      assert out =~ "BOOT_REFUSED"

      reason = refusal_line(out)

      assert reason =~ "regulated_llm_endpoints_unset",
             "it refused, but the printed reason is not the one under test:\n#{reason}"

      # The refusal names the variable the operator has to set, not only that something is unset.
      assert reason =~ "TRINITY_REGULATED_LLM_ENDPOINTS"
    end
  end

  describe "3. regulated refuses the local authority" do
    test "everything else correct, but TRINITY_AUTHORITY unset, does not start" do
      {root, tag} = case_setup("regulated-local-authority")

      script = """
      #{production_mcp_auth()}
      #{allowed_models()}
      #{@report}
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
          ],
          script
        )

      assert status == 3, "the node started on the local authority:\n#{out}"

      reason = refusal_line(out)

      assert reason =~ "regulated_refuses_local_authority",
             "it refused, but the printed reason is not the one under test:\n#{reason}"
    end
  end

  describe "4. regulated boots when every condition is met" do
    test "production mcp_auth, a non-Local authority, an allowed endpoint and a signer" do
      {root, tag} = case_setup("regulated-good")

      script = """
      #{@fixture}
      #{production_mcp_auth()}
      #{allowed_models()}
      #{@report}
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "RegulatedBootFixture"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
          ],
          script
        )

      assert status == 0,
             """
             a correctly configured regulated node refused to boot. If this fails while 2 and 3 \
             pass, the profile refuses everything and proves nothing.

             #{String.slice(out, -4000, 4000)}
             """

      assert out =~ "BOOT_OK"
    end
  end

  describe "5. regulated refuses an MCP authorization profile that is not production" do
    test "personal and local are both refused, where case 4's configuration is otherwise met" do
      for profile <- ["personal", "local"] do
        {root, tag} = case_setup("regulated_mcp_#{profile}")

        # Set here rather than through `TRINITY_MCP_AUTH_PROFILE`. That variable is mapped by
        # `config/runtime.exs`, inside a block guarded by `config_env() != :test`, so under the
        # child's `MIX_ENV=test` it is read by nothing. Passing it would have looked like a test of
        # the operator's path while actually testing an unset profile, and the case would have gone
        # green on a node that refused for the default reason instead of the one named.
        script = """
        Application.put_env(:trinity, :mcp_auth, profile: :#{profile})
        #{@fixture}
        #{allowed_models()}
        #{@report}
        """

        {out, status} =
          boot(
            [
              {"XDG_DATA_HOME", root},
              {"TRINITY_BOOT_TAG", tag},
              {"TRINITY_PROFILE", "regulated"},
              {"TRINITY_AUTHORITY", "RegulatedBootFixture"},
              {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
            ],
            script
          )

        assert status == 3,
               """
               the node started on the #{profile} MCP authorization profile. Case 4 is the same \
               configuration with production, and it starts, so this is the only difference.

               #{String.slice(out, -3000, 3000)}
               """

        assert out =~ "BOOT_REFUSED"

        reason = refusal_line(out)

        assert reason =~ "regulated_requires_production_mcp_auth",
               "it refused, but the printed reason is not the one under test:\n#{reason}"

        # The reason names the profile that was refused, not just that one was.
        assert reason =~ ":#{profile}"
      end
    end
  end

  describe "7. regulated refuses a gateway that is not on the allow-list" do
    test "a configured adapter refuses without the allow-list and boots with it" do
      # Both directions in one case, as case 5 does for two profiles. Without the second half a
      # refusal proves only that the check fires, not that it can be satisfied.
      configured = """
      Application.put_env(:trinity, :gateways, adapters: [Trinity.Gateways.Console])
      """

      {root, tag} = case_setup("regulated_gateway_unlisted")

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "RegulatedBootFixture"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
          ],
          """
          #{@fixture}
          #{production_mcp_auth()}
          #{allowed_models()}
          #{configured}
          #{@report}
          """
        )

      assert status == 3, "the node started with an unlisted gateway:\n#{out}"
      reason = refusal_line(out)

      assert reason =~ "regulated_gateways_unset",
             "it refused, but the printed reason is not the one under test:\n#{reason}"

      assert reason =~ "TRINITY_REGULATED_GATEWAYS"

      # Named, and it starts. The adapter is unchanged; only the allow-list differs.
      {root2, tag2} = case_setup("regulated_gateway_listed")

      {out2, status2} =
        boot(
          [
            {"XDG_DATA_HOME", root2},
            {"TRINITY_BOOT_TAG", tag2},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "RegulatedBootFixture"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"},
            {"TRINITY_REGULATED_GATEWAYS", "Trinity.Gateways.Console"}
          ],
          """
          #{@fixture}
          #{production_mcp_auth()}
          #{allowed_models()}
          #{configured}
          #{@report}
          """
        )

      assert status2 == 0,
             """
             the allow-list named the configured adapter and the node still refused. If this fails \
             while the half above passes, the profile refuses every gateway rather than an unnamed \
             one, which is not the rule.

             #{String.slice(out2, -3000, 3000)}
             """

      assert out2 =~ "BOOT_OK"
    end
  end

  describe "6. regulated refuses to keep running when receipts cannot be appended" do
    test "case 4's configuration with case 1's broken key store does not start" do
      {root, tag} = case_setup("regulated-signer-down")

      # Exactly case 4, plus the one break case 1 survives. Nothing else differs, so a refusal here
      # is attributable to the key store and to the profile, and to nothing else.
      script = """
      #{@fixture}
      #{production_mcp_auth()}
      #{allowed_models()}
      r = Application.get_env(:trinity, :receipts, [])
      Application.put_env(:trinity, :receipts, Keyword.put(r, :keys_dir, "#{broken_keys_dir(root)}"))
      #{@report}
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_BOOT_TAG", tag},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "RegulatedBootFixture"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
          ],
          script
        )

      assert status == 3,
             """
             a regulated node started with the signer down. Case 1 proves the same key store does \
             not stop a :default node, and that difference is the whole point of AC4.

             #{String.slice(out, -4000, 4000)}
             """

      assert out =~ "BOOT_REFUSED"

      reason = refusal_line(out)

      assert reason =~ "regulated_boot_refused",
             "it refused, but the printed reason is not the receipts check:\n#{reason}"

      assert reason =~ "regulated_requires_receipts"

      # The underlying signer failure is carried through rather than flattened into a bare atom.
      assert reason =~ "key_file"
    end
  end
end
