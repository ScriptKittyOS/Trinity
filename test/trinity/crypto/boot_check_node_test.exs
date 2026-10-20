# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.BootCheckNodeTest do
  @moduledoc """
  Slice 143, AC4 and AC5 at the only place their refusals are real: a boot, in a separate OS
  process, by `Trinity.ToolchainNodeTest`'s recipe (`XDG_DATA_HOME` and `Trinity.BootIsolation` per
  case, `MIX_ENV=test`, `mix run --no-start`, assertions on the one line the child prints).

  The child inherits this VM's runtime and mode, so each expectation comes from this VM, read here
  and not from the code under test: whether ML-DSA-87 signs (`MLDSA87Oracle`), and the mode
  `crypto:info_fips/0` reports. Each run prints which branch it took.
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

      receipt =
        Enum.find_value(1..50, fn _ ->
          Trinity.Receipts.boot_receipt() || (Process.sleep(100) && nil)
        end)

      IO.puts("VERIFIER " <> ((receipt && receipt.subject["mldsa87_verifier"]) || "none"))
      System.halt(0)

    {:error, reason} ->
      IO.puts("BOOT_REFUSED " <> inspect(reason, limit: :infinity, printable_limit: :infinity))
      System.halt(3)
  end
  """

  @nss """
  r = Application.get_env(:trinity, :receipts, [])
  Application.put_env(:trinity, :receipts, Keyword.put(r, :profile, :nss))
  """

  defp boot(name, script, env \\ []) do
    tag = Trinity.BootIsolation.tag(name)
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    root = Path.join(System.tmp_dir!(), "bootcheck-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    System.cmd("mix", ["run", "--no-start", "-e", @isolate <> script],
      env:
        [
          {"MIX_ENV", "test"},
          {"TRINITY_PROFILE", nil},
          {"TRINITY_AUTHORITY", nil},
          {"XDG_DATA_HOME", root},
          {"TRINITY_BOOT_TAG", tag}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp refusal(out) do
    out
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "BOOT_REFUSED"))
    |> String.replace(~S(\"), ~S("))
  end

  describe "AC4: the verifier check at boot" do
    # The seam plants a wrong answer on the first case, which the check reaches on every runtime. A
    # tree whose boot does not run the check, or does not refuse on a wrong answer, boots: this
    # test's red.
    test "a node whose verifier answers a case wrongly refuses, naming the case, in every profile" do
      for {profile, extra} <- [{"commercial", ""}, {"nss", @nss}] do
        {out, status} =
          boot(
            "wrong-#{profile}",
            extra <>
              ~s|Application.put_env(:trinity, :mldsa87_preflight_fault, "acvp_siggen_tc63")\n| <>
              @report
          )

        line = refusal(out)

        assert status == 3,
               "#{profile}: a node with a wrong verifier booted:\n" <>
                 String.slice(out, -3000, 3000)

        # On nss the provider's identity is asked first, and on every CI runtime it refuses first.
        if profile == "commercial",
          do: assert(line =~ ~s|{:mldsa87_verifier_wrong, "acvp_siggen_tc63", :planted}|, line),
          else: assert(line =~ "nss_", line)
      end
    end

    test "on commercial the runtime's own answer decides, and the boot receipt says it" do
      {out, status} = boot("commercial-unplanted", @report)
      assert status == 0, String.slice(out, -3000, 3000)
      want = if Trinity.TestSupport.MLDSA87Oracle.signs?(), do: "ok", else: "unavailable"
      assert [_, got] = Regex.run(~r/^VERIFIER (\S+)$/m, out), out
      assert got == want

      IO.puts(
        "boot_check_node_test: a commercial node boots, its verifier #{got} (fips #{:crypto.info_fips()})"
      )
    end
  end

  describe "AC5: on nss" do
    # No CI runtime carries CMVP #5523's provider, so an nss node refuses on every leg; which reason
    # depends on the mode, which this VM reports. The pass is `boot_check_test.exs`'s.
    test "an nss node refuses, naming the mode or the provider's build string" do
      {out, status} = boot("nss", @nss <> @report)
      line = refusal(out)
      assert status == 3, "an nss node booted:\n" <> String.slice(out, -3000, 3000)

      case :crypto.info_fips() do
        :enabled ->
          assert line =~ "{:nss_fips_provider_buildinfo, ", line
          assert line =~ ~s|"3.6.0-r4"}|, line

        mode ->
          assert line =~ "{:nss_requires_fips_mode, #{inspect(mode)}}", line
      end

      IO.puts("boot_check_node_test: an nss node refuses (fips #{:crypto.info_fips()}): " <> line)
    end
  end
end
