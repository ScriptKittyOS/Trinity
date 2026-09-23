# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule NoEvalOnModelOutputTest do
  use ExUnit.Case, async: true
  alias Trinity.Credo.NoEvalOnModelOutput

  @moduledoc """
  The conventions name one function. One function has an obvious bypass, so the check covers the
  family, and there is one test per function.
  """

  defp issues(code), do: NoEvalOnModelOutput.triggers(code)

  defp wrap(call), do: "defmodule Probe do\n  def go(input), do: #{call}\nend\n"

  for {label, call} <- [
        {"Code.eval_string", "Code.eval_string(input)"},
        {"Code.eval_quoted", "Code.eval_quoted(input)"},
        {"Code.eval_file", "Code.eval_file(input)"},
        {"Code.compile_string", "Code.compile_string(input)"},
        {"Code.compile_quoted", "Code.compile_quoted(input)"},
        {":erl_eval.exprs", ":erl_eval.exprs(input, [])"}
      ] do
    test "RED: #{label} is flagged" do
      assert [{trigger, line}] = issues(wrap(unquote(call)))
      assert line == 2
      assert trigger =~ unquote(label) |> String.replace(".exprs", "")
    end
  end

  test "GREEN: ordinary code is not flagged" do
    assert issues(wrap("String.upcase(input)")) == []
    assert issues(wrap("Jason.decode!(input)")) == []
  end

  test "GREEN: a variable merely named eval_string is not flagged" do
    assert issues(
             "defmodule P do\n  def go do\n    eval_string = 1\n    eval_string\n  end\nend\n"
           ) == []
  end

  test "the family is exactly the six the moduledoc names" do
    {code_funs, erl} = NoEvalOnModelOutput.forbidden()

    assert Enum.sort(code_funs) ==
             Enum.sort([:eval_string, :eval_quoted, :eval_file, :compile_string, :compile_quoted])

    assert erl == :erl_eval
  end
end
