# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.RegistryTest do
  @moduledoc "Slice 020 AC1 and AC9, and the registry's admission rules."
  use ExUnit.Case, async: false

  alias Trinity.TestTools
  alias Trinity.Tools
  alias Trinity.Tools.Registry

  setup do
    on_exit(fn ->
      for %{kind: :dynamic, name: n} <- Registry.list(), do: Registry.unregister(n)
    end)

    :ok
  end

  describe "AC1: a module plus one config line" do
    test "the four test tools are listed, in the core toolset, with schemas that build and digests" do
      names = Enum.map(Tools.list(), & &1.name)

      assert names == [
               "big",
               "crash",
               "delegate",
               "echo",
               "fs_edit",
               "fs_glob",
               "fs_grep",
               "fs_list",
               "fs_read",
               "fs_write",
               "learn",
               "memory",
               "recall",
               "session_search",
               "shell",
               "skill_file",
               "skill_manage",
               "skill_view",
               "skills_list",
               "sleep",
               "web_fetch",
               "web_search",
               "write_note"
             ]

      assert Enum.map(Tools.list(toolset: :core), & &1.name) == [
               "big",
               "crash",
               "echo",
               "sleep",
               "write_note"
             ]

      for entry <- Tools.list() do
        assert entry.kind == :core
        assert Tools.Schema.valid_schema?(entry.module.schema())
        assert String.length(entry.digest) == 64
      end
    end

    test "to_llm_tools/0 carries name, description and parameters for each" do
      tools = Tools.to_llm_tools()

      assert Enum.map(tools, & &1.name) == [
               "big",
               "crash",
               "delegate",
               "echo",
               "fs_edit",
               "fs_glob",
               "fs_grep",
               "fs_list",
               "fs_read",
               "fs_write",
               "learn",
               "memory",
               "recall",
               "session_search",
               "shell",
               "skill_file",
               "skill_manage",
               "skill_view",
               "skills_list",
               "sleep",
               "web_fetch",
               "web_search",
               "write_note"
             ]

      for t <- tools do
        assert is_binary(t.description) and t.description != ""
        assert t.parameters["type"] == "object"
      end
    end

    test "no core module references a test tool (the diff for AC1 is config and test/support only)" do
      {out, 0} =
        System.cmd("git", ["grep", "-l", "TestTools", "--", "lib/"], stderr_to_stdout: true)

      assert out == ""
    rescue
      # git grep exits 1 when nothing matches, which is the assertion.
      e in MatchError -> assert {_, 1} = e.term
    end
  end

  describe "dynamic tools" do
    test "a namespaced tool with no catalog claim is admitted, listed and removable" do
      assert {:ok, %{kind: :dynamic, name: "mcp:fake:echo"}} =
               Tools.register(TestTools.DynamicEcho)

      assert {:ok, _} = Tools.lookup("mcp:fake:echo")
      assert "mcp:fake:echo" in Enum.map(Tools.list(), & &1.name)
      assert :ok = Tools.unregister("mcp:fake:echo")
      assert {:error, :unknown_tool} = Tools.lookup("mcp:fake:echo")
    end

    test "AC9: a dynamic tool named exactly like a core tool is refused, and a namespaced one gets no tier" do
      assert {:error, {:name_not_namespaced, "echo"}} = Tools.register(TestTools.Impostor)
      assert {:ok, %{module: TestTools.Echo}} = Tools.lookup("echo")
      assert {:ok, _} = Tools.register(TestTools.DynamicEcho)
      assert Trinity.Permissions.tier("mcp:fake:echo") == :ask
      # Slice 021: a core tool's declared risk is its tier, handed over by the registry.
      assert Trinity.Permissions.tier("echo") == :read
    end

    test "a runtime registration claiming :catalog is refused by name" do
      assert {:error, :catalog_is_compile_time} = Tools.register(TestTools.CatalogClaimer)
      assert {:error, :unknown_tool} = Tools.lookup("mcp:planted:send_money")
    end

    test "a core name cannot be unregistered, a module that is not a tool cannot be registered" do
      assert {:error, :core_tool} = Tools.unregister("echo")
      assert {:error, {:not_a_tool, Enum}} = Tools.register(Enum)
    end
  end
end
