# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Credo.NoEvalOnModelOutput do
  @moduledoc """
  CLAUDE.md §5: "No `Code.eval_string` on model output. Ever."

  The rule names one function, and one function has an obvious bypass, so this check covers the
  whole evaluation family. Sandboxed execution goes through `Trinity.Sandbox` (slice 110), never
  through runtime evaluation of a string the model produced.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Runtime evaluation of model output is arbitrary code execution with extra steps.

      Forbidden: Code.eval_string/2,3, Code.eval_quoted/2,3, Code.eval_file/1,2,
      Code.compile_string/1,2, Code.compile_quoted/1,2, and the :erl_eval module.
      """
    ]

  @forbidden_code ~w(eval_string eval_quoted eval_file compile_string compile_quoted)a

  @doc "The forbidden `Code` functions, and the forbidden Erlang module."
  @spec forbidden() :: {[atom()], atom()}
  def forbidden, do: {@forbidden_code, :erl_eval}

  @doc """
  Every forbidden call in the given source, as `{trigger, line}`.

  Pure and independent of Credo's server, so the red can be planted directly in a test.
  Parsing uses `Code.string_to_quoted/1`, which builds an AST and evaluates nothing.
  """
  @spec triggers(String.t()) :: [{String.t(), pos_integer()}]
  def triggers(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> ast |> Macro.prewalk([], &collect/2) |> elem(1) |> Enum.reverse()
      {:error, _} -> []
    end
  end

  defp collect({{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _} = ast, acc)
       when fun in @forbidden_code do
    {ast, [{"Code.#{fun}", meta[:line]} | acc]}
  end

  defp collect({{:., _, [:erl_eval, fun]}, meta, _} = ast, acc) do
    {ast, [{":erl_eval.#{fun}", meta[:line]} | acc]}
  end

  defp collect(ast, acc), do: {ast, acc}

  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.source()
    |> triggers()
    |> Enum.map(fn {trigger, line} -> issue_for(issue_meta, line, trigger) end)
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message: "#{trigger} evaluates code at runtime; forbidden on model output (CLAUDE.md §5)",
      trigger: trigger,
      line_no: line_no
    )
  end
end
