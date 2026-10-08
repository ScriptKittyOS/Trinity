# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.BootRefusalNodeTest do
  @moduledoc """
  Slice 136 AC4 and AC13 at the only place they are real: a boot, in a separate OS process.

  The same arrangement as `test/trinity/regulated_boot_node_test.exs` (whose moduledoc says why a
  child process, why `MIX_ENV=test`, and what `Trinity.BootIsolation` does): each case is its own
  `mix run --no-start` with its own data directory and databases, and asserts on the line the
  child printed.

  Every regulated case starts from the configuration that test's case 4 proves boots (production
  MCP authorization, a non-Local authority, an allowed model endpoint) and changes only the web
  pages' bind, mode, or proxy setting, so a refusal is attributable to the one thing changed. The
  refused cases bind `0.0.0.0` in configuration only: they never start the endpoint, which is the
  point. The cases that boot bind the loopback.

  The whole matrix of tuples is `test/trinity/web_auth_test.exs`, as pure calls; these are the
  tuples AC4 and AC13 name, booted.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  """

  @fixture """
  defmodule WebBootFixture do
    @behaviour Trinity.Authority
    def stage(staged, _ctx), do: {:ok, staged}
    def decide(_staged, decision, _ctx), do: {:ok, decision, "fixture"}
    def execute(_staged, _decision, _ctx), do: {:error, :not_used}
    def receipt(_kind, _attrs), do: {:error, :not_used}
  end
  Application.put_env(:trinity, :mcp_auth, profile: :production)
  llm = Application.get_env(:trinity, :llm, [])
  Application.put_env(:trinity, :llm, Keyword.put(llm, :models, [
    %{id: "allowed", provider: :req_llm, model: "openai:x",
      base_url: "https://models.internal/v1", api_key_env: "NONE",
      caps: [:stream], price: %{input: 0.0, output: 0.0}}
  ]))
  """

  # The tail: start, then print the boot receipt's `web` subject so the case can assert the mode
  # it booted in was recorded. The receipt is written by a task after the receipts supervisor, so
  # it is polled for rather than assumed present.
  @report """
  case Application.ensure_all_started(:trinity) do
    {:ok, _} ->
      receipt =
        Enum.find_value(1..50, fn _ ->
          case Trinity.Receipts.boot_receipt() do
            nil -> Process.sleep(100); nil
            r -> r
          end
        end)

      IO.puts("BOOT_OK " <> Jason.encode!((receipt && receipt.subject["web"]) || %{}))
      System.halt(0)

    {:error, reason} ->
      IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
      System.halt(3)
  end
  """

  defp case_setup(name) do
    tag = Trinity.BootIsolation.tag(name)
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    dir = Path.join(System.tmp_dir!(), "webboot-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, tag}
  end

  # `bind` and `mode` are put into the child's configuration ahead of the start; `env` is the
  # child's environment beyond the isolation and the regulated baseline.
  defp boot(name, bind, mode, extra_script \\ "", env \\ []) do
    {root, tag} = case_setup(name)

    script = """
    #{@isolate}
    #{@fixture}
    ep = Application.get_env(:trinity, TrinityWeb.Endpoint, [])
    Application.put_env(:trinity, TrinityWeb.Endpoint,
      Keyword.put(ep, :http, ip: #{inspect(bind)}, port: 0))
    wa = Application.get_env(:trinity, :web_auth, [])
    Application.put_env(:trinity, :web_auth,
      Keyword.merge(wa, mode: #{inspect(mode)}, token: String.duplicate("t", 32)))
    #{extra_script}
    #{@report}
    """

    base = [
      {"MIX_ENV", "test"},
      {"XDG_DATA_HOME", root},
      {"TRINITY_BOOT_TAG", tag},
      {"TRINITY_PROFILE", "regulated"},
      {"TRINITY_AUTHORITY", "WebBootFixture"},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"},
      {"TRINITY_MCP_AUTH_PROFILE", nil},
      {"TRINITY_WEB_AUTH", nil},
      {"TRINITY_TRUSTED_PROXY", nil}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", script],
      env: Enum.reduce(env, base, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end),
      stderr_to_stdout: true
    )
  end

  defp line(out, prefix),
    do: out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, prefix))

  describe "AC4: regulated, a bind other machines can reach, no user authentication" do
    test "none on 0.0.0.0 refuses to boot, naming the mode, the address and the variable" do
      {out, status} = boot("reg_none_wide", {0, 0, 0, 0}, :none)
      assert status == 3, "a regulated node served pages with no login on 0.0.0.0:\n#{out}"
      reason = line(out, "BOOT_REFUSED")
      assert reason =~ "regulated_requires_user_authentication", reason
      assert reason =~ ":none"
      assert reason =~ "0.0.0.0"
      assert reason =~ "TRINITY_WEB_AUTH"
    end

    test "local_token on 0.0.0.0 refuses to boot, with a valid token configured" do
      {out, status} = boot("reg_token_wide", {0, 0, 0, 0}, :local_token)

      assert status == 3,
             "a regulated node served pages behind a shared token on 0.0.0.0:\n#{out}"

      reason = line(out, "BOOT_REFUSED")
      assert reason =~ "regulated_requires_user_authentication", reason
      assert reason =~ ":local_token"
    end

    test "unset on 0.0.0.0 refuses to boot (the rule of every profile)" do
      {out, status} = boot("reg_unset_wide", {0, 0, 0, 0}, nil)
      assert status == 3, out
      assert line(out, "BOOT_REFUSED") =~ "web_auth_unset_on_non_loopback_bind"
    end

    test "none on the loopback boots, and the boot receipt records the mode and the bind" do
      {out, status} = boot("reg_none_loopback", {127, 0, 0, 1}, :none)

      assert status == 0,
             """
             the loopback case refused. If this fails while the refusals pass, the profile refuses
             everything and proves nothing.

             #{String.slice(out, -4000, 4000)}
             """

      "BOOT_OK " <> json = line(out, "BOOT_OK")
      assert %{"mode" => "none", "bind" => "127.0.0.1", "loopback" => true} = Jason.decode!(json)
    end
  end

  describe "AC13: regulated, x-forwarded-proto believed, no trusted proxy declared" do
    @rewrite """
    ep = Application.get_env(:trinity, TrinityWeb.Endpoint, [])
    Application.put_env(:trinity, TrinityWeb.Endpoint,
      Keyword.put(ep, :force_ssl, rewrite_on: [:x_forwarded_proto]))
    """

    test "TRINITY_TRUSTED_PROXY unset refuses to boot; set, the same node boots" do
      {out, status} = boot("reg_rewrite_unset", {127, 0, 0, 1}, :none, @rewrite)

      assert status == 3,
             "a regulated node believed x-forwarded-proto with no proxy declared:\n#{out}"

      reason = line(out, "BOOT_REFUSED")
      assert reason =~ "regulated_rewrite_on_without_trusted_proxy", reason
      assert reason =~ "TRINITY_TRUSTED_PROXY"

      {out2, status2} =
        boot("reg_rewrite_set", {127, 0, 0, 1}, :none, @rewrite, [
          {"TRINITY_TRUSTED_PROXY", "true"}
        ])

      assert status2 == 0,
             """
             the operator declared the proxy and the node still refused; the check refuses every
             rewrite rather than an undeclared one.

             #{String.slice(out2, -4000, 4000)}
             """
    end
  end

  describe "every profile: a wider bind with the mode unset" do
    test "the default profile refuses too, naming the variable" do
      {out, status} =
        boot("default_unset_wide", {0, 0, 0, 0}, nil, "", [{"TRINITY_PROFILE", "default"}])

      assert status == 3, "a default node served pages with no login on 0.0.0.0:\n#{out}"
      assert line(out, "BOOT_REFUSED") =~ "web_auth_unset_on_non_loopback_bind"
    end
  end
end
