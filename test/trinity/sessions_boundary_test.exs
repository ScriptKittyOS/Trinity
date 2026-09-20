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

  test "a TrinityWeb module calling Store fails the compile; the same call through Sessions passes" do
    path = "lib/trinity_web/zz_boundary_probe.ex"
    on_exit(fn -> File.rm(path) end)

    File.write!(path, @violation)
    {out_red, code_red} = compile()
    assert code_red != 0
    assert out_red =~ "forbidden reference to Trinity.Sessions.Store"
    assert out_red =~ "zz_boundary_probe.ex"

    File.write!(path, @lawful)
    {out_green, code_green} = compile()
    assert code_green == 0, out_green

    File.rm!(path)
    {_, 0} = compile()
  end

  defp compile do
    System.cmd("mix", ["compile", "--warnings-as-errors"],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
