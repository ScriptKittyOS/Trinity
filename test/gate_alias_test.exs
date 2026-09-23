# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule GateAliasTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Measured at slice 000: `boundary` reports violations as warnings, so a planted violation
  exits 0 without `--warnings-as-errors`. The flag IS the enforcement, and these tests make
  removing it fail the gate rather than silently turning the architecture rules advisory.
  """

  defp gate_steps do
    Mix.Project.config()[:aliases][:gate]
  end

  test "the gate has a compile step and it carries --warnings-as-errors" do
    compile = Enum.find(gate_steps(), &String.starts_with?(&1, "compile"))
    assert compile, "the gate alias has no compile step"

    assert compile =~ "--warnings-as-errors",
           "the gate's compile step must carry --warnings-as-errors: boundary reports " <>
             "violations as warnings, so without it a boundary violation exits 0. Got: #{compile}"
  end

  test "the gate runs every enforcer as its own step" do
    steps = gate_steps()

    for required <- ~w(format credo sobelow hex.audit deps.audit trinity.version_form
                       trinity.names trinity.secrets.scan trinity.reuse test trinity.coverage) do
      # Containment, not prefix: hex.audit runs as "cmd env ERL_AFLAGS= mix hex.audit" so it gets its own OS
      # process and its own exit code. The property is that the gate runs it, not how it is spelled.
      assert Enum.any?(steps, &String.contains?(&1, required)),
             "the gate is missing the #{required} step. Steps: #{inspect(steps)}"
    end
  end

  test "the release check runs inside the gate, so a green gate cannot coexist with a broken release" do
    steps = Mix.Project.config()[:aliases][:gate]

    assert Enum.any?(steps, &(&1 =~ "prod_check.sh")),
           "the gate does not run scripts/prod_check.sh. MIX_ENV=test says nothing about what " <>
             "ships: a plug's init/1 is called at compile time under prod, and a closure there " <>
             "once broke the release build while every gate stayed green."

    assert Enum.count(steps, &(&1 =~ "prod_check.sh")) == 1,
           "the release check appears more than once in the gate"

    # One command, one exit code: the gate is the whole contract rather than one of two things
    # a person has to remember to run and read.
    assert List.last(steps) == "trinity.coverage",
           "the gate's last step is #{inspect(List.last(steps))}"
  end

  test "sobelow blocks rather than advises" do
    sobelow = Enum.find(gate_steps(), &String.starts_with?(&1, "sobelow"))
    assert sobelow =~ "--exit", "sobelow must block (M5): #{sobelow}"
  end
end
