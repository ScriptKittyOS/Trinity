# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SecretsBootNodeTest do
  @moduledoc """
  Slice 135, AC2 and AC4, at the only place they are real: a boot in a separate OS process.

  The child is built the way `Trinity.RegulatedBootNodeTest` builds one (its own `XDG_DATA_HOME`,
  its own databases through `Trinity.BootIsolation`, `MIX_ENV=test`), and additionally gets its own
  `TRINITY_SECRETS_DIR`.

  **AC2.** A root equal to, above or below the data directory or the secrets directory refuses the
  boot, with a named reason, in every profile. One child tries each of the six relations under both
  profiles, starting and stopping the application between attempts, and prints one line per
  attempt; the parent asserts on those lines.

  **AC4.** A data directory laid out the way every earlier release laid it out (the receipt key and
  its registry in `<data dir>/keys`, receipts already signed with that key) boots, the key moves to
  the secrets directory, the move is on the signed record, and every receipt written before the move
  still verifies. The first child writes the old layout by pointing the signer at `<data dir>/keys`
  exactly as the previous default did; the second boots with nothing pinned.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  """

  defp case_setup(name) do
    tag = Trinity.BootIsolation.tag(name)
    dir = Path.join(System.tmp_dir!(), "s135boot-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Trinity.BootIsolation.drop!(tag)
      File.rm_rf(dir)
    end)

    {dir, tag}
  end

  defp boot(env, script) do
    base = [
      {"MIX_ENV", "test"},
      {"TRINITY_PROFILE", nil},
      {"TRINITY_AUTHORITY", nil},
      {"TRINITY_REGULATED_LLM_ENDPOINTS", nil},
      {"TRINITY_MCP_AUTH_PROFILE", nil},
      {"TRINITY_FS_ROOTS", nil}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", @isolate <> script],
      env: base ++ env,
      stderr_to_stdout: true
    )
  end

  describe "AC2: a root overlapping the data or secrets directory refuses the boot" do
    test "equal, ancestor and descendant of either, under :default and :regulated" do
      {root, tag} = case_setup("roots")
      # Two separate branches, so an ancestor of one is not an ancestor of the other.
      xdg = Path.join(root, "xdg")
      data = Path.join(xdg, "trinity")
      secrets = Path.join([root, "sec", "secrets"])

      cases = [
        {"equal_data", data},
        {"ancestor_data", xdg},
        {"descendant_data", Path.join(data, "sub")},
        {"equal_secrets", secrets},
        {"ancestor_secrets", Path.dirname(secrets)},
        {"descendant_secrets", Path.join(secrets, "sub")}
      ]

      script = """
      File.mkdir_p!(#{inspect(Path.join(data, "sub"))})
      File.mkdir_p!(#{inspect(Path.join(secrets, "sub"))})

      # The dependencies once, so each attempt starts and stops :trinity alone: a refused start
      # rolls back what that call started, and some dependencies cannot be started twice.
      for app <- Application.spec(:trinity, :applications), do: {:ok, _} = Application.ensure_all_started(app)

      for profile <- ["default", "regulated"],
          {name, r} <- #{inspect(cases)} do
        System.put_env("TRINITY_PROFILE", profile)
        Application.put_env(:trinity, :fs, roots: [r])

        line =
          case Application.ensure_all_started(:trinity) do
            {:ok, _} ->
              Application.stop(:trinity)
              "BOOT_OK"

            {:error, reason} ->
              "BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity)
          end

        IO.puts("CASE " <> profile <> " " <> name <> " " <> line)
      end

      System.halt(0)
      """

      {out, status} =
        boot(
          [
            {"XDG_DATA_HOME", xdg},
            {"TRINITY_SECRETS_DIR", secrets},
            {"TRINITY_BOOT_TAG", tag}
          ],
          script
        )

      assert status == 0, String.slice(out, -3000, 3000)
      lines = out |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "CASE "))
      assert length(lines) == 12, "expected twelve attempts:\n#{String.slice(out, -3000, 3000)}"

      for line <- lines do
        assert line =~ "BOOT_REFUSED", "this attempt booted: #{line}"
        assert line =~ "fs_root_overlaps", "it refused, but not for the root: #{line}"

        which = if line =~ "_data ", do: "data_dir", else: "secrets_dir"
        assert line =~ which, "the reason does not name #{which}: #{line}"

        relation =
          cond do
            line =~ " equal_" -> "equal"
            line =~ " ancestor_" -> "ancestor"
            true -> "descendant"
          end

        assert line =~ relation, "the reason does not name the relation #{relation}: #{line}"
      end
    end
  end

  describe "AC4: secrets migrate out of the data directory on boot" do
    test "keys under <data dir>/keys move to the secrets directory, receipted, and old receipts verify" do
      {root, tag} = case_setup("migrate")
      data = Path.join(root, "trinity")
      secrets = Path.join(root, "secrets")
      env = [{"XDG_DATA_HOME", root}, {"TRINITY_SECRETS_DIR", secrets}, {"TRINITY_BOOT_TAG", tag}]

      # The layout every release before this one wrote: the signer's keys directory is
      # `<data dir>/keys`, which is what `Trinity.Paths.keys_dir/0` answered.
      old = """
      r = Application.get_env(:trinity, :receipts, [])
      Application.put_env(:trinity, :receipts, Keyword.put(r, :keys_dir, #{inspect(Path.join(data, "keys"))}))
      {:ok, _} = Application.ensure_all_started(:trinity)
      %{key_id: kid} = Trinity.Receipts.KeyCustody.selected()
      IO.puts("OLD_KEY " <> kid)
      IO.puts("OLD_COUNT " <> Integer.to_string(Trinity.Receipts.count("boot")))
      System.halt(0)
      """

      {out, 0} = boot(env, old)
      [_, old_kid] = Regex.run(~r/OLD_KEY (\S+)/, out)
      assert File.regular?(Path.join([data, "keys", "receipts-ed25519.key"])), out

      # The same data directory, booted with nothing pinned, as a release would.
      new = """
      Application.put_env(:trinity, Trinity.Secrets.Migration, enabled: true)
      r = Application.get_env(:trinity, :receipts, [])
      Application.put_env(:trinity, :receipts, Keyword.delete(r, :keys_dir))
      {:ok, _} = Application.ensure_all_started(:trinity)
      %{key_id: kid, key_path: path} = Trinity.Receipts.KeyCustody.selected()
      IO.puts("NEW_KEY " <> kid)
      IO.puts("NEW_PATH " <> path)
      boot = Trinity.Receipts.boot_receipt()
      IO.puts("MOVE " <> JSON.encode!(JSON.decode!(boot.signed_payload)["subject"]["secrets_migration"]))
      {:ok, export} = Trinity.Receipts.export("boot")
      IO.puts("COUNT " <> Integer.to_string(length(export["receipts"])))
      IO.puts("VERIFY " <> inspect(Trinity.Receipts.Verifier.verify(export |> JSON.encode!() |> JSON.decode!())))
      System.halt(0)
      """

      {out, status} = boot(env, new)
      assert status == 0, String.slice(out, -3000, 3000)
      [_, new_kid] = Regex.run(~r/NEW_KEY (\S+)/, out)
      [_, new_path] = Regex.run(~r/NEW_PATH (\S+)/, out)

      assert new_kid == old_kid, "the key was replaced rather than moved"
      assert Path.dirname(new_path) == Path.join(secrets, "keys")
      refute File.exists?(Path.join([data, "keys", "receipts-ed25519.key"]))
      assert {:ok, %{mode: mode}} = File.stat(new_path)
      assert Bitwise.band(mode, 0o777) == 0o400
      assert {:ok, %{mode: dmode}} = File.stat(Path.join(secrets, "keys"))
      assert Bitwise.band(dmode, 0o777) == 0o700

      [_, move] = Regex.run(~r/MOVE (.+)/, out)
      move = JSON.decode!(move)
      assert move["to"] == Path.join(secrets, "keys")
      assert "receipts-ed25519.key" in move["files"]

      [_, count] = Regex.run(~r/COUNT (\d+)/, out)
      assert String.to_integer(count) >= 2, "the earlier boot's receipt is in the chain"
      assert out =~ "VERIFY {:ok,", "the chain does not verify after the move:\n#{out}"
    end
  end

  describe "AC5: under :regulated, network: :allow with no egress allow-list refuses the boot" do
    # Everything `Trinity.RegulatedBootNodeTest` case 4 needs to boot a regulated node, and no
    # TRINITY_REGULATED_EGRESS; then the same with it.
    @fixture """
    defmodule SecretsBootFixture do
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
    case Application.ensure_all_started(:trinity) do
      {:ok, _} -> IO.puts("BOOT_OK"); System.halt(0)
      {:error, reason} ->
        IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
        System.halt(3)
    end
    """

    defp regulated_env(root, tag, extra) do
      [
        {"XDG_DATA_HOME", root},
        {"TRINITY_SECRETS_DIR", Path.join(root, "secrets")},
        {"TRINITY_BOOT_TAG", tag},
        {"TRINITY_PROFILE", "regulated"},
        {"TRINITY_AUTHORITY", "SecretsBootFixture"},
        {"TRINITY_REGULATED_LLM_ENDPOINTS", "https://models.internal"}
      ] ++ extra
    end

    test "no TRINITY_REGULATED_EGRESS: refused, and the reason names it" do
      {root, tag} = case_setup("egress-unset")

      {out, status} =
        boot(regulated_env(root, tag, [{"TRINITY_REGULATED_EGRESS", nil}]), @fixture)

      assert status == 3,
             "a regulated node with network: :allow and no egress list booted:\n#{out}"

      line = out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "BOOT_REFUSED"))
      assert line =~ "regulated_network_allow_without_egress_allowlist", line
      assert line =~ "TRINITY_REGULATED_EGRESS", line
    end

    test "with TRINITY_REGULATED_EGRESS set, the same node boots" do
      {root, tag} = case_setup("egress-set")

      {out, status} =
        boot(regulated_env(root, tag, [{"TRINITY_REGULATED_EGRESS", "docs.internal"}]), @fixture)

      assert status == 0, String.slice(out, -3000, 3000)
      assert out =~ "BOOT_OK"
    end
  end
end
