# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.CensusTest do
  @moduledoc """
  Slice 041 AC8: exactly one apply path. The population is every source file in `lib/` and
  `test/support/` that `git ls-files` names. (1) The callers of `Promotion.swap(` are
  `Trinity.Skills.Manager` and the planted `Trinity.TestSkills.Bypass`, which must be there
  or the census is not looking. (2) Under `lib/trinity/skills/`, the modules that write to
  the filesystem (`File.write`, `File.mkdir_p`, `File.rename`, `File.cp_r`, `File.rm_rf`) are
  the proposer (`Staging`, every target under the pending root) and the promotion
  (`Promotion`, the rename into the root behind the approval); a planted writer in
  `test/support` is flagged by the same grep. (3) `swap/3` itself requires an approval id:
  `staging_test.exs` proves the refusals by name.
  """
  use ExUnit.Case, async: true

  @swap_callers ["lib/trinity/skills/manager.ex"]
  @swap_planted ["test/support/skills/bypass.ex"]
  @writers ["lib/trinity/skills/promotion.ex", "lib/trinity/skills/staging.ex"]
  @write_re ~r/File\.(write!?|mkdir_p!?|rename!?|cp_r!?|cp!?|rm_rf!?|rm!?)\(/

  defp files(patterns) do
    {out, 0} = System.cmd("git", ["ls-files" | patterns])
    String.split(out, "\n", trim: true)
  end

  test "the callers of Promotion.swap/3 are the manager and the plant" do
    files = files(["lib/*.ex", "test/support/*.ex"])
    assert length(files) > 100

    callers =
      for f <- files,
          src = File.read!(f),
          Regex.match?(~r/[Pp]romotion(\(\))?\.swap\(/, src),
          do: f

    assert Enum.sort(callers) == Enum.sort(@swap_callers ++ @swap_planted)
  end

  test "under lib/trinity/skills the filesystem writers are the proposer and the promotion, and nothing else" do
    writers =
      for f <- files(["lib/trinity/skills/*.ex", "lib/trinity/skills.ex"]),
          src = File.read!(f),
          Regex.match?(@write_re, src),
          do: f

    assert Enum.sort(writers) == @writers
  end

  test "the planted writer is caught by the writers' grep, and the plant is a real second path" do
    src = File.read!("test/support/skills/bypass.ex")
    assert Regex.match?(@write_re, src)

    assert Code.ensure_loaded?(Trinity.TestSkills.Bypass) and
             function_exported?(Trinity.TestSkills.Bypass, :apply_anyway, 2)

    # swap/3 with no approval refuses even from the plant: the id is what gates, not the caller.
    assert {:error, :approval_required} =
             Trinity.TestSkills.Bypass.apply_anyway(%Trinity.Skills.Change{}, nil)
  end

  test "every write in the proposer targets the pending directory: its paths derive from pending_dir/0 or a change_dir under it" do
    src = File.read!("lib/trinity/skills/staging.ex")
    # The proposer builds one directory, under pending_dir/0, and writes only below it; the
    # discard removes a change_dir it first checks against the pending root.
    assert src =~ ~r/dir = Path\.join\(\[pending_dir\(\), name, id\]\)/

    assert src =~
             ~r/String\.starts_with\?\(Path\.expand\(dir\), root <> "\/"\), do: File\.rm_rf!\(dir\)/

    refute src =~ "Sources.user_dir()) |> File"
    assert Regex.scan(~r/File\.(write!?|mkdir_p!?)\(/, src) |> length() == 3
  end
end
