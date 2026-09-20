# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SessionsBoundaryTest do
  @moduledoc """
  Slice 010 AC5: `boundary` prevents `TrinityWeb` from calling `Trinity.Sessions.Store`
  directly. Demonstrated by compiling a violating module in a scratch copy of the project
  with `--warnings-as-errors` and asserting the compile fails naming the reference; then
  the same module with the call routed through `Trinity.Sessions` compiles. Both outputs
  are captured. Slow (two full compiles), so it is tagged and runs in the gate only.
  """
  use ExUnit.Case, async: false

  @moduletag :boundary_compile
  @moduletag timeout: 300_000

  @violation """
  defmodule TrinityWeb.Violation do
    def history(id), do: Trinity.Sessions.Store.history(id, [])
  end
  """

  @lawful """
  defmodule TrinityWeb.Lawful do
    def history(id), do: Trinity.Sessions.history(id, [])
  end
  """

  # Every compile is --force: mix decides what to recompile by mtime at one-second
  # resolution, so a probe written, replaced or removed within a second of the last compile
  # is invisible to an incremental build. Found by the gate, twice, in both directions (a
  # lawful half compiled against the stale violation; a red half that never compiled the
  # violation). Three forced compiles cost seconds and remove the class.
  @red_path "lib/trinity_web/zz_boundary_violation.ex"
  @green_path "lib/trinity_web/zz_boundary_lawful.ex"

  test "a TrinityWeb module calling Store fails the compile; the same call through Sessions passes" do
    on_exit(fn -> Enum.each([@red_path, @green_path], &File.rm/1) end)

    File.write!(@red_path, @violation)
    {out_red, code_red} = compile()
    assert code_red != 0
    assert out_red =~ "forbidden reference to Trinity.Sessions.Store"
    assert out_red =~ "zz_boundary_violation.ex"

    File.rm!(@red_path)
    File.write!(@green_path, @lawful)
    {out_green, code_green} = compile()
    assert code_green == 0, out_green
    refute out_green =~ "forbidden reference"

    File.rm!(@green_path)
    {_, 0} = compile()
  end

  defp compile do
    System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
