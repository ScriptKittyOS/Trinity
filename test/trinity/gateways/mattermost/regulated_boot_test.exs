# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.RegulatedBootTest do
  @moduledoc """
  Slice 072, AC4: a regulated node **refuses to boot** with the Mattermost adapter configured
  unless it is named on `TRINITY_REGULATED_GATEWAYS`. The check is the existing one
  (`Trinity.Profile.check_gateways/3`, asked by `Trinity.Application` before any child starts);
  `test/trinity/regulated_boot_node_test.exs` case 7 asserts it for `Console`. This asserts it for
  this adapter, configured the way an operator configures it (named by `TRINITY_GATEWAYS` from the
  `available:` list, its server in `config :trinity, :mattermost`), in a boot rather than in a
  function call.

  Each case is a separate OS process, isolated as that file's are (`XDG_DATA_HOME`,
  `Trinity.BootIsolation`, `MIX_ENV=test`), and asserts on the one line the child printed. Three
  cases: refused with no allow-list, refused with an allow-list that names another adapter, and
  booted with it named, where the child also reports the adapter running under the gateway
  supervisor, so the positive case is the adapter actually starting and not only the check passing.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  """

  # Everything else a regulated node needs, as case 4 of the generic file sets it, so the gateway
  # allow-list is the only thing that differs between these cases.
  @regulated """
  defmodule RegulatedBootFixture do
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
  # The adapter as an operator configures it: a server that is not there, and a token variable
  # that is not set. Neither may stop a boot the profile admits.
  Application.put_env(:trinity, :gateways,
    available: [Trinity.Gateways.Console, Trinity.Gateways.Mattermost], enabled: ["mattermost"])
  Application.put_env(:trinity, :mattermost,
    url: "http://127.0.0.1:9", token_env: "MATTERMOST_BOOT_TEST_UNSET")
  """

  @report """
  case Application.ensure_all_started(:trinity) do
    {:ok, _} ->
      running = is_pid(Process.whereis(Trinity.Gateways.Mattermost))
      under = Supervisor.which_children(Trinity.Gateways.Supervisor) |> Enum.map(&elem(&1, 0))
      IO.puts("BOOT_OK mattermost_running=" <> inspect(running) <> " under=" <> inspect(under))
      System.halt(0)

    {:error, reason} ->
      IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
      System.halt(3)
  end
  """

  defp boot(name, allow_list) do
    tag = Trinity.BootIsolation.tag(name)
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    root = Path.join(System.tmp_dir!(), "mmboot-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    env = [
      {"MIX_ENV", "test"},
      {"XDG_DATA_HOME", root},
      {"TRINITY_BOOT_TAG", tag},
      {"TRINITY_PROFILE", "regulated"},
      {"TRINITY_AUTHORITY", "RegulatedBootFixture"},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"},
      {"TRINITY_MCP_AUTH_PROFILE", nil},
      {"TRINITY_REGULATED_GATEWAYS", allow_list}
    ]

    {out, status} =
      System.cmd("mix", ["run", "--no-start", "-e", @isolate <> @regulated <> @report],
        env: env,
        stderr_to_stdout: true
      )

    line =
      out
      |> String.split("\n")
      |> Enum.find(
        "",
        &(String.starts_with?(&1, "BOOT_OK") or String.starts_with?(&1, "BOOT_REFUSED"))
      )

    {line, status, out}
  end

  test "AC4: with Mattermost configured and no allow-list, a regulated node refuses to boot" do
    {line, status, out} = boot("mm_unset", nil)
    assert status == 3, "the node started:\n#{String.slice(out, -3000, 3000)}"
    assert line =~ "regulated_gateways_unset"
    assert line =~ "TRINITY_REGULATED_GATEWAYS"
  end

  test "AC4: an allow-list naming another adapter does not admit Mattermost, and says which" do
    {line, status, out} = boot("mm_other", "Trinity.Gateways.Console")
    assert status == 3, "the node started:\n#{String.slice(out, -3000, 3000)}"
    assert line =~ "regulated_gateway_not_allowed"
    assert line =~ "Trinity.Gateways.Mattermost"
  end

  test "AC4: named on the allow-list, the node boots and the adapter runs under the gateway supervisor" do
    {line, status, out} = boot("mm_named", "Trinity.Gateways.Mattermost")

    assert status == 0, """
    the allow-list named the adapter and the node still refused. If this fails while the two
    above pass, the profile refuses Mattermost outright rather than an unnamed gateway.

    #{String.slice(out, -4000, 4000)}
    """

    assert line =~ "mattermost_running=true"
    assert line =~ "Trinity.Gateways.Mattermost"
    assert line =~ "Trinity.Gateways.Router"
  end
end
