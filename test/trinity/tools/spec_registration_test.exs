# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.SpecRegistrationTest do
  @moduledoc """
  Slice 060: a dynamic tool registered as a module plus a spec. The entry's definition is
  the spec's (listed, digested, validated from it); the module's `execute/2` learns which
  tool it is from the context; a spec claiming `:catalog` is refused, as is a core tool
  with a spec.
  """
  use Trinity.DataCase, async: false

  alias Trinity.TestTools.ContextEcho
  alias Trinity.Tools
  alias Trinity.Tools.{Registry, Runner}

  @spec_a %{
    name: "mcp:spec:alpha",
    description: "alpha, from the spec",
    schema: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"]
    },
    risk: :read,
    effect: :none,
    timeout: 1_234
  }

  setup do
    on_exit(fn ->
      for %{name: name, kind: :dynamic} <- Tools.list(), String.starts_with?(name, "mcp:spec:") do
        Tools.unregister(name)
      end
    end)
  end

  test "the entry's name, description, schema, risk, effect, timeout and digest are the spec's; two specs share one module" do
    assert {:ok, entry_a} = Tools.register(ContextEcho, spec: @spec_a)

    assert {:ok, entry_b} =
             Tools.register(ContextEcho,
               spec: %{@spec_a | name: "mcp:spec:beta", description: "beta"}
             )

    assert %{
             name: "mcp:spec:alpha",
             module: ContextEcho,
             kind: :dynamic,
             risk: :read,
             effect: :none
           } = entry_a

    assert Registry.description(entry_a) == "alpha, from the spec"
    assert Registry.schema(entry_a) == @spec_a.schema
    assert Registry.timeout(entry_a) == 1_234
    assert entry_a.digest == Registry.definition_digest(entry_a)
    assert entry_a.digest != entry_b.digest
    assert entry_a.digest != Registry.definition_digest(ContextEcho)

    assert %{description: "beta", parameters: %{"required" => ["text"]}} =
             Enum.find(Tools.to_llm_tools(), &(&1.name == "mcp:spec:beta"))
  end

  test "the runner validates against the spec's schema and hands execute/2 the tool name in the context" do
    {:ok, _} = Tools.register(ContextEcho, spec: @spec_a)

    # The tier of a namespaced name is :ask whatever the spec's risk says (docs/07): a rule allows it.
    {:ok, rule} =
      Trinity.Permissions.put_rule(%{tool: "mcp:spec:alpha", pattern: "*", decision: "allow"})

    on_exit(fn -> Trinity.Permissions.revoke_rule(rule.id) end)
    ctx = %{session_id: nil, cwd: nil, caller: self()}

    assert {:ok, %{content: "mcp:spec:alpha:hi"}, _} =
             Runner.run(%{id: "c1", name: "mcp:spec:alpha", args: %{"text" => "hi"}}, ctx)

    assert {:error, {:invalid_args, _}, _} =
             Runner.run(%{id: "c2", name: "mcp:spec:alpha", args: %{}}, ctx)
  end

  test "a spec claiming :catalog is refused; an ill-formed spec is refused; a core tool may not carry one" do
    assert {:error, :catalog_is_compile_time} =
             Tools.register(ContextEcho, spec: %{@spec_a | effect: :catalog})

    assert {:error, {:invalid_spec, {:risk, :bogus}}} =
             Tools.register(ContextEcho, spec: %{@spec_a | risk: :bogus})

    assert {:error, {:invalid_spec, {:timeout, 0}}} =
             Tools.register(ContextEcho, spec: %{@spec_a | timeout: 0})

    assert {:error, {:invalid_spec, _}} = Tools.register(ContextEcho, spec: %{name: "mcp:spec:x"})

    assert {:error, {:name_not_namespaced, "alpha"}} =
             Tools.register(ContextEcho, spec: %{@spec_a | name: "alpha"})

    # The spec's fields fall back to the module's when absent.
    assert {:ok, %{risk: :ask, effect: :none}} =
             Tools.register(ContextEcho, spec: Map.drop(@spec_a, [:risk, :effect, :timeout]))
  end
end
