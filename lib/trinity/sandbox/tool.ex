# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.Tool do
  @moduledoc """
  `run_lua`: a Lua script in the sandbox (slice 110).

  Risk `:exec`, because a program is a program and the tier is a function of the tool's name. Effect
  `:none`, because the script itself reaches nothing: it computes, and anything it wants *done* it
  asks for through `trinity.tool`, which is decided by the gate a second time under that tool's own
  tier. The two are different questions and this answers only the first.

  **Why this exists rather than the model doing the arithmetic.** A model asked to total a column
  will produce a number that looks right. A script produces a number that is right, and leaves the
  script in the transcript for anyone to check. What the sandbox adds is that running it costs no
  trust: no operating system process, no filesystem handle, no socket, and a wall-clock and heap
  limit the VM enforces.

  **It lives in the sandbox's boundary rather than in `Trinity.Tools`.** `Trinity.Sandbox` depends on
  `Trinity`, which contains the tools, so a tool module inside `Trinity.Tools` that reached back into
  the sandbox would close a cycle the boundary compiler refuses. The same shape as the MCP bridge,
  which implements this behaviour from its own boundary. The registry lists modules from
  configuration by name, so where a tool lives is a question about dependencies and not about
  discovery.

  Results come back wrapped as untrusted, like any tool result: the script's output may be derived
  from a file or a page, and a result re-entering the prompt is data rather than command
  (`docs/07-security-model.md`).
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Sandbox
  alias Trinity.Tools.{Context, Untrusted}

  @max_code_bytes 20_000

  @impl true
  def name, do: "run_lua"

  @impl true
  def description,
    do:
      "Runs a Lua 5.3 script in an in-process sandbox and returns its value. Use it for arithmetic, " <>
        "counting, filtering and any answer that should be computed rather than estimated. The " <>
        "script has no filesystem, no network and no operating system: to act, call " <>
        "`trinity.tool(name, args)`, which goes through the permission gate exactly as a direct " <>
        "tool call does. Also available: `trinity.log(text)`, `trinity.result(table)` to declare a " <>
        "structured answer, and `json.encode`/`json.decode`. A run is bounded in time and memory."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "code" => %{"type" => "string", "description" => "The Lua source to run"},
        "max_time_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 30_000,
          "description" =>
            "Wall-clock bound for the run (default #{Keyword.fetch!(Sandbox.defaults(), :max_time_ms)})"
        }
      },
      "required" => ["code"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :exec

  @impl true
  def effect, do: :none

  @impl true
  def execute(%{"code" => code}, %Context{}) when byte_size(code) > @max_code_bytes,
    do: {:error, {:script_too_long, byte_size(code), @max_code_bytes}}

  @impl true
  def execute(%{"code" => code} = args, %Context{} = ctx) do
    opts = [context: ctx] ++ time_opt(args)

    case Sandbox.run(code, opts) do
      {:ok, value, stats} -> {:ok, ok_result(value, stats)}
      {:error, reason} -> {:ok, refusal_result(reason)}
    end
  end

  defp time_opt(%{"max_time_ms" => ms}) when is_integer(ms), do: [max_time_ms: ms]
  defp time_opt(_), do: []

  # A refused run is a *result*, not a tool error: the model asked a legitimate question and the
  # answer is that the script did not finish. Returning an error would end the turn; returning the
  # reason lets it write a smaller script.
  defp refusal_result(reason) do
    Untrusted.result(explain(reason),
      tool: name(),
      source_ref: "sandbox",
      meta: %{"refused" => true}
    )
  end

  defp explain({:timeout, ms}),
    do:
      "The script did not finish within #{ms} ms and was stopped. Make it do less, or raise max_time_ms."

  defp explain(:heap_exceeded),
    do:
      "The script used more memory than the sandbox allows and was stopped by the virtual machine."

  defp explain({:pool_full, cap}),
    do: "#{cap} scripts are already running. Try again when one finishes."

  defp explain({:lua_error, reason}), do: "The script raised: #{inspect(reason)}"
  defp explain(other), do: "The script did not run: #{inspect(other)}"

  defp ok_result(value, stats) do
    text = render(value)
    logged = if stats.log == [], do: "", else: "\n\n-- log --\n" <> Enum.join(stats.log, "\n")

    meta = %{
      "reductions" => stats.reductions,
      "time_ms" => stats.time_ms,
      "log_lines" => length(stats.log)
    }

    Untrusted.result(text <> logged, tool: name(), source_ref: "sandbox", meta: meta)
  end

  defp render([single]), do: render(single)
  defp render(value) when is_binary(value), do: value
  defp render(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp render(nil), do: "nil"
  defp render(other), do: inspect(other, limit: 200, printable_limit: 4_000)
end
