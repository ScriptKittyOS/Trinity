# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SandboxTest do
  @moduledoc """
  Slice 110 AC1, AC2 and AC3: the limits bind, and the machine is not reachable.

  Every assertion here is about a **refusal**, which is the only thing a sandbox is for. A test that
  a script can add two numbers proves the interpreter works; these prove the walls do.
  """
  use ExUnit.Case, async: true

  alias Trinity.Sandbox

  describe "it runs Lua" do
    test "a value comes back with statistics that are actually measured" do
      assert {:ok, [2], stats} = Sandbox.run("return 1+1")
      assert is_integer(stats.time_ms)

      assert stats.reductions > 0,
             "reductions came back as #{stats.reductions}. The first version read the count from " <>
               "the caller after the runner had exited, so it was always zero: a statistic that " <>
               "is always zero is worse than none, because it looks like a measurement"
    end

    test "more work reports more reductions, so the number tracks something real" do
      {:ok, _, small} = Sandbox.run("return 1+1")
      {:ok, _, larger} = Sandbox.run("local s = 0 for i = 1, 20000 do s = s + i end return s")

      assert larger.reductions > small.reductions * 2,
             "a loop of twenty thousand iterations reported #{larger.reductions} against " <>
               "#{small.reductions} for an addition"
    end

    test "a Lua error is a value, not an exception in the caller" do
      assert {:error, {:lua_error, _}} = Sandbox.run("error('no')")
    end

    test "a syntax error is a value too" do
      assert {:error, _} = Sandbox.run("this is not lua")
    end
  end

  describe "AC1: a script that will not stop is stopped, and the caller survives" do
    test "an infinite loop is killed on wall clock and the caller is told which limit bound" do
      caller = self()
      assert {:error, {:timeout, 200}} = Sandbox.run("while true do end", max_time_ms: 200)
      assert Process.alive?(caller)
    end

    test "the VM is unharmed: the node still runs Lua immediately afterwards" do
      for _ <- 1..4, do: Sandbox.run("while true do end", max_time_ms: 100)

      # The proof that matters is not a utilisation number, which is noisy on a shared runner, but
      # that the node is still doing useful work immediately afterwards.
      assert {:ok, [4], _} = Sandbox.run("return 2+2")
      assert Process.alive?(self())
    end

    test "the runner process is gone, not merely unreferenced" do
      before = length(Process.list())
      for _ <- 1..10, do: Sandbox.run("while true do end", max_time_ms: 50)
      Process.sleep(200)

      assert length(Process.list()) - before < 10,
             "runner processes accumulated, so a killed script leaks a process per run"
    end
  end

  describe "AC2: a memory bomb is killed by the VM" do
    @tag timeout: 60_000
    test "a table that grows without bound dies, and the app is healthy after it" do
      code = "local t = {} local i = 1 while true do t[i] = string.rep('x', 1000) i = i + 1 end"

      assert {:error, reason} = Sandbox.run(code, max_heap_words: 200_000, max_time_ms: 20_000)

      assert reason == :heap_exceeded or match?({:timeout, _}, reason),
             "expected the heap limit or the clock to stop it, got #{inspect(reason)}"

      assert {:ok, [2], _} = Sandbox.run("return 1+1")
    end
  end

  describe "AC3: the machine is not reachable" do
    test "the dangerous members of os are gone" do
      for name <- ~w(execute exit getenv remove rename tmpname) do
        assert {:error, {:lua_error, _}} = Sandbox.run("return os.#{name}(0)"),
               "os.#{name} is callable inside the sandbox"
      end
    end

    test "io is gone wholesale" do
      assert {:error, {:lua_error, _}} = Sandbox.run("return io.open(0)")
      assert {:error, {:lua_error, _}} = Sandbox.run("return io.write(0)")
    end

    test "the loaders are gone: require, load, loadstring, loadfile, dofile" do
      for name <- ~w(require load loadstring loadfile dofile) do
        assert {:error, {:lua_error, _}} = Sandbox.run("return #{name}(0)"),
               "#{name} is callable inside the sandbox, so code can be brought in from outside it"
      end
    end

    test "package is gone, so no module path is exposed" do
      # `package` is replaced by a sandboxed value, and indexing one yields nil rather than raising.
      # So the assertion that means something is that no real path comes back, not that reading it
      # errors: the first version of this test expected an error and was simply wrong about Lua.
      assert {:ok, [nil], _} = Sandbox.run("return package.path")
      assert {:error, {:lua_error, _}} = Sandbox.run("return package.loadlib(0, 0)")
    end

    test "what survives is named rather than discovered: os.time and os.clock still work" do
      # Not a hole, and not an accident either. These reach no resource, but they are
      # non-deterministic, which matters when a script's output can reach a receipt.
      assert {:ok, [_], _} = Sandbox.run("return os.time()")
      assert {:ok, [_], _} = Sandbox.run("return os.clock()")
    end
  end
end
