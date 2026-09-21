# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.StdioEnvTest do
  @moduledoc """
  Slice 060: the stdio child's environment is the process basics and the row's `env_refs`;
  a variable this VM holds that the row does not name is not there. Proven with `env` as
  the command: its output is the child's environment, read back through the transport's
  own line handling (an `env` line is not JSON, so the transport warns and drops it; the
  test reads the Port directly instead).
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Trinity.MCP.Client.Transport.Stdio
  alias Trinity.MCP.ServerConfig

  @tag :unix
  test "a variable outside the allow list and the refs is unset for the child; a ref is passed; PATH and HOME stay" do
    System.put_env("TRINITY_TEST_SECRET", "must-not-leak")
    System.put_env("TRINITY_TEST_REF", "passed")

    on_exit(fn ->
      System.delete_env("TRINITY_TEST_SECRET")
      System.delete_env("TRINITY_TEST_REF")
    end)

    env_path = System.find_executable("env")

    dump =
      Path.join(System.tmp_dir!(), "trinity-mcp-env-#{System.unique_integer([:positive])}.txt")

    on_exit(fn -> File.rm(dump) end)

    # `sh -c 'env > file'`: the child's own environment, written where the test reads it.
    config = %ServerConfig{
      name: "envprobe",
      transport: "stdio",
      command: "sh",
      args: ["-c", "#{env_path} > #{dump}; sleep 30"],
      env_refs: ["TRINITY_TEST_REF"]
    }

    {:ok, pid} = Stdio.connect(config, self(), [])
    on_exit(fn -> Stdio.close(pid) end)
    wait_for(fn -> File.exists?(dump) and File.read!(dump) =~ "PATH=" end)

    lines = dump |> File.read!() |> String.split("\n", trim: true)
    names = Enum.map(lines, &(&1 |> String.split("=", parts: 2) |> hd()))

    assert "TRINITY_TEST_REF=passed" in lines
    refute "TRINITY_TEST_SECRET" in names
    assert "PATH" in names and "HOME" in names
    # PWD, SHLVL and `_` are the shell's own, set by `sh` for its child.
    shells_own = ~w(PWD SHLVL OLDPWD _)

    assert Enum.all?(
             names,
             &(&1 in Stdio.kept_variables() or &1 == "TRINITY_TEST_REF" or &1 in shells_own)
           )
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the child never wrote its environment")
      true -> Process.sleep(50) && wait_for(fun, tries - 1)
    end
  end
end
