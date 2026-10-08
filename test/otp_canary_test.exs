# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.OtpCanaryTest do
  @moduledoc """
  `scripts/otp_canary.sh` and `.github/workflows/otp-canary.yml` (owner decision D2, ADR-0014).
  The probe's network half runs only in CI; what is checked here is what it would ask about and
  what its flip writes.
  """

  use ExUnit.Case, async: true

  @script "scripts/otp_canary.sh"
  @fetcher "deps/burrito/lib/util/erts_universal_machine_fetcher.ex"

  test "the probe asks for the URLs Burrito itself fetches" do
    script = File.read!(@script)
    fetcher = File.read!(@fetcher)

    for {var, attr} <- [linux_url: "@linux_url", mac_url: "@mac_url", windows_url: "@windows_url"] do
      [_, ours] = Regex.run(~r/^#{var}='([^']+)'$/m, script)
      [_, burritos] = Regex.run(~r/^\s*#{attr} "([^"]+)"$/m, fetcher)
      assert ours == burritos, "#{var} in #{@script} is not #{attr} in #{@fetcher}"
    end
  end

  test "the probe covers every desktop target mix.exs names" do
    targets = Mix.Project.config()[:releases][:desktop][:burrito][:targets]
    assert Enum.sort(Keyword.keys(targets)) == [:linux_x86_64, :macos_aarch64, :windows_x86_64]
    script = File.read!(@script)

    assert script =~
             ~s{"$(url "$linux_url" x86_64)" "$(url "$mac_url" -)" "$(url "$windows_url" -)"}
  end

  # The copy's container pin is a version no file names, so the test holds whatever the two pins
  # are today, including after a flip has made them agree.
  @next "28.5.0.99"

  @tag :tmp_dir
  test "flip moves the desktop pin to the container's, and only that", %{tmp_dir: dir} do
    desktop = erlang(File.read!(".tool-versions"))
    copy_tree(dir)
    assert {out, 0} = run("flip", dir)
    assert out =~ "desktop pin #{desktop} -> #{@next}"

    assert erlang(File.read!(Path.join(dir, ".tool-versions"))) == @next
    versions = File.read!(Path.join(dir, "lib/trinity/versions.ex"))
    assert versions =~ ~s|pin: "**#{@next}**"|
    assert versions =~ ~s|from: {:file, ".tool-versions", "erlang #{@next}"}|
    refute versions =~ ~s|"erlang #{desktop}"|

    # Everything else in the pin list is as it was.
    assert String.replace(versions, @next, desktop) == File.read!("lib/trinity/versions.ex")

    assert {out, 0} = run("flip", dir)
    assert out =~ "already agree"
  end

  @tag :tmp_dir
  test "flip writes nothing when the tree has drifted from what it expects", %{tmp_dir: dir} do
    desktop = erlang(File.read!(".tool-versions"))
    copy_tree(dir)
    path = Path.join(dir, "lib/trinity/versions.ex")

    File.write!(
      path,
      String.replace(File.read!(path), ~s|pin: "**#{desktop}**"|, ~s|pin: "#{desktop}"|)
    )

    assert {out, status} = run("flip", dir)
    assert status != 0
    assert out =~ "nothing written"
    assert File.read!(Path.join(dir, ".tool-versions")) == File.read!(".tool-versions")
  end

  test "the workflow runs daily and on demand, and opens at most one pull request per version" do
    workflow = File.read!(".github/workflows/otp-canary.yml")
    assert workflow =~ ~r/schedule:\n\s+- cron: "[^"]+"/
    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "scripts/otp_canary.sh probe"
    assert workflow =~ "scripts/otp_canary.sh flip"
    assert workflow =~ ~s{gh pr list --head "$BRANCH" --state all}
  end

  defp copy_tree(dir) do
    for path <- [".tool-versions", "lib/trinity/versions.ex"] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.cp!(path, Path.join(dir, path))
    end

    File.mkdir_p!(Path.join(dir, "ci"))
    File.write!(Path.join(dir, "ci/container.tool-versions"), "erlang #{@next}\n")
  end

  defp erlang(text) do
    [_, version] = Regex.run(~r/^erlang (\S+)$/m, text)
    version
  end

  defp run(command, dir) do
    System.cmd("bash", [@script, command],
      env: [{"TRINITY_REPO", dir}],
      stderr_to_stdout: true
    )
  end
end
