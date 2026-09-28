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

  `MIX_ENV=dev`, deliberately, and not `test`. The test environment puts both repos on
  `Ecto.Adapters.SQL.Sandbox`, and a child process with no sandbox owner blocks on checkout rather
  than booting: that is the trap slice 126 was opened for and then retracted over.

  `mix run --no-start`, so the script can set application environment and define a fixture module
  **before** `Application.ensure_all_started/1` runs the code under test.

  Nothing here touches `:persistent_term` in this VM. Every mutation happens in the child.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  # A signer failure the child can reproduce: the key file exists as a directory, so `File.read/1`
  # answers `{:error, :eisdir}` and `KeyCustody.boot!/1` answers `{:error, {:key_file, :eisdir}}`.
  # `keys_dir` itself is a real directory, so nothing raises on the way there.
  defp broken_keys_dir(root) do
    dir = Path.join(root, "broken-keys")
    File.mkdir_p!(Path.join(dir, "receipts-ed25519.key"))
    dir
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
      {"MIX_ENV", "dev"},
      {"TRINITY_FAKE_PROVIDER", "1"},
      # Never inherit this suite's values for anything the code under test reads.
      {"TRINITY_PROFILE", nil},
      {"TRINITY_AUTHORITY", nil},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", nil},
      {"TRINITY_MCP_AUTH_PROFILE", nil}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", script],
      env: base ++ env,
      stderr_to_stdout: true
    )
  end

  # The tail of every script: start the application and say what happened.
  @report """
  case Application.ensure_all_started(:trinity) do
    {:ok, _} -> IO.puts("BOOT_OK"); System.halt(0)
    {:error, reason} -> IO.puts("BOOT_REFUSED " <> inspect(reason, limit: 3)); System.halt(3)
  end
  """

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
      root = tmp!("default-signer-down")

      script = """
      r = Application.get_env(:trinity, :receipts, [])
      Application.put_env(:trinity, :receipts, Keyword.put(r, :keys_dir, "#{broken_keys_dir(root)}"))
      #{@report}
      """

      {out, status} = boot([{"XDG_DATA_HOME", root}], script)

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
      root = tmp!("regulated-no-endpoints")

      script = """
      #{@fixture}
      #{production_mcp_auth()}
      #{@report}
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_AUTHORITY", "RegulatedBootFixture"}
          ],
          script
        )

      assert status == 3, "the node started with no endpoint allow-list:\n#{out}"
      assert out =~ "BOOT_REFUSED"

      assert out =~ "regulated_llm_endpoints_unset",
             "it refused, but not for the reason under test:\n#{String.slice(out, -3000, 3000)}"

      assert out =~ "TRINITY_REGULATED_LLM_ENDPOINTS"
    end
  end

  describe "3. regulated refuses the local authority" do
    test "everything else correct, but TRINITY_AUTHORITY unset, does not start" do
      root = tmp!("regulated-local-authority")

      script = """
      #{production_mcp_auth()}
      #{allowed_models()}
      #{@report}
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", root},
            {"TRINITY_PROFILE", "regulated"},
            {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
          ],
          script
        )

      assert status == 3, "the node started on the local authority:\n#{out}"

      assert out =~ "regulated_refuses_local_authority",
             "it refused, but not for the reason under test:\n#{String.slice(out, -3000, 3000)}"
    end
  end

  describe "4. regulated boots when every condition is met" do
    test "production mcp_auth, a non-Local authority, an allowed endpoint and a signer" do
      root = tmp!("regulated-good")

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
end
