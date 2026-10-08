# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.CensusTest do
  @moduledoc """
  Slice 072, AC1: an adapter carries text and nothing else. It calls no LLM, touches no session
  directly, and decides no approval (docs/07, "Gateways"; slice 070 states the rule and this is
  the test that holds the layer to it).

  **The population comes from the tree.** Every module the `:trinity` application compiled that
  declares `@behaviour Trinity.Gateways.Adapter` is an adapter, and every module nested under one
  is part of it. Each one's compiled import table (every remote call the compiler emitted) is read
  and checked against the forbidden namespaces. A new adapter is covered the day it is compiled,
  without anyone remembering to add it here.

  **Stated limit.** An import table records the calls the compiler can see. A call made through
  `apply/3` with a module computed at run time is not in it; nor is a message sent to a process.
  The router is the one road to a session (`Trinity.Gateways.Router`), and an adapter's calls to it
  are allowed: that is how it hands text on.
  """
  use ExUnit.Case, async: true

  @forbidden [
    {"Trinity.LLM", "calls no LLM"},
    {"Trinity.Sessions", "touches no session directly"},
    {"Trinity.Permissions", "decides no approval"},
    {"Trinity.Effects", "runs no effect"},
    {"Trinity.Tools", "runs no tool"}
  ]

  defp adapters do
    {:ok, modules} = :application.get_key(:trinity, :modules)

    Enum.filter(modules, fn module ->
      behaviours =
        if Code.ensure_loaded?(module),
          do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
          else: []

      Trinity.Gateways.Adapter in behaviours
    end)
  end

  defp parts(adapter) do
    {:ok, modules} = :application.get_key(:trinity, :modules)
    prefix = Atom.to_string(adapter) <> "."
    [adapter | Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), prefix))]
  end

  # The compiled file, read from the application's ebin: under `mix test --cover` the loaded
  # module is cover-compiled and `:code.which/1` answers `:cover_compiled`, not a path.
  defp imports(module) do
    beam = Path.join(Application.app_dir(:trinity, "ebin"), "#{module}.beam")
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(String.to_charlist(beam), [:imports])
    imports
  end

  test "the population is not empty, and holds the adapters this tree ships" do
    found = adapters()
    assert Trinity.Gateways.Console in found
    assert Trinity.Gateways.Mattermost in found
    assert length(parts(Trinity.Gateways.Mattermost)) > 5
  end

  test "AC1: no adapter, nor any module of one, calls the LLM, a session, the gate, an effect or a tool" do
    violations =
      for adapter <- adapters(),
          module <- parts(adapter),
          {callee, function, arity} <- imports(module),
          name = Atom.to_string(callee) |> String.replace_prefix("Elixir.", ""),
          {namespace, rule} <- @forbidden,
          name == namespace or String.starts_with?(name, namespace <> "."),
          do: "#{inspect(module)} calls #{name}.#{function}/#{arity}: an adapter #{rule}"

    assert violations == [], Enum.join(violations, "\n")
  end

  test "AC1: an adapter hands text to the router, which is how it reaches a session at all" do
    calls =
      for module <- parts(Trinity.Gateways.Mattermost),
          {Trinity.Gateways.Router, function, _} <- imports(module),
          do: function

    assert :inbound in calls
  end
end
