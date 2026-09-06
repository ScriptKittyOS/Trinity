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

  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when fun in @forbidden_code do
    {ast, [issue_for(issue_meta, meta[:line], "Code.#{fun}") | issues]}
  end

  defp traverse({{:., _, [:erl_eval, fun]}, meta, _args} = ast, issues, issue_meta) do
    {ast, [issue_for(issue_meta, meta[:line], ":erl_eval.#{fun}") | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message: "#{trigger} evaluates code at runtime; forbidden on model output (CLAUDE.md §5)",
      trigger: trigger,
      line_no: line_no
    )
  end
end
