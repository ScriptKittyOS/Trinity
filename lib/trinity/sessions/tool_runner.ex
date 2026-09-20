# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.ToolRunner do
  @moduledoc """
  The seam through which a Session runs a tool call. Slice 012 shipped the stub; slice 020's
  `Trinity.Tools.Runner` was the implementation in force; slice 024's `Trinity.Effects.Runner`
  is, routing effectful calls through the membrane and receipting every decision. The
  Session depends on this behaviour and never on the runtime.
  """

  @type call :: %{id: String.t(), name: String.t(), args: map()}
  @type meta :: map()
  @type result :: {:ok, Trinity.Tools.Result.t(), meta()} | {:error, term(), meta()}

  @doc "One call. Slice 012's shape, kept for the stub and for callers with one call."
  @callback run(call(), context :: map()) :: result()

  @doc """
  Every call of a turn, all at once, each answered in the order given (slice 020). The
  Session records one `tool` row per answer, carrying the meta (the tool's name and its
  definition digest) beside the content.
  """
  @callback run_all([call()], context :: map()) :: [{call(), result()}]

  @doc "The implementation in force, from config; `Trinity.Effects.Runner` by default (slice 024)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:trinity, :tool_runner, Trinity.Effects.Runner)

  @doc "Runs one call through the implementation in force."
  @spec run(call(), map()) :: result()
  def run(call, context), do: impl().run(call, context)

  @doc "Runs a turn's calls through the implementation in force."
  @spec run_all([call()], map()) :: [{call(), result()}]
  def run_all(calls, context), do: impl().run_all(calls, context)

  defmodule Stub do
    @moduledoc "No tools: every call is an error that says so. The implementation before slice 020, kept for tests that want no runtime."
    @behaviour Trinity.Sessions.ToolRunner

    @impl true
    def run(_call, _context), do: {:error, :no_tools, %{}}

    @impl true
    def run_all(calls, _context), do: Enum.map(calls, &{&1, {:error, :no_tools, %{}}})
  end
end
