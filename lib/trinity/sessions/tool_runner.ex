# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.ToolRunner do
  @moduledoc """
  The seam through which a Session runs a tool call. Slice 012 ships the stub; slice 020
  replaces it with the real runtime and slice 024 routes effectful calls through the membrane.
  The state machine's `tool_wait` path is complete now, with every call answered by an error.
  """

  @type call :: %{id: String.t(), name: String.t(), args: map()}
  @type result :: {:ok, String.t()} | {:error, term()}

  @callback run(call(), context :: map()) :: result()

  @doc "The implementation in force, from config; the stub by default."
  @spec impl() :: module()
  def impl, do: Application.get_env(:trinity, :tool_runner, __MODULE__.Stub)

  @doc "Runs one call through the implementation in force."
  @spec run(call(), map()) :: result()
  def run(call, context), do: impl().run(call, context)

  defmodule Stub do
    @moduledoc "No tools exist before slice 020; every call is an error that says so."
    @behaviour Trinity.Sessions.ToolRunner

    @impl true
    def run(_call, _context), do: {:error, :no_tools}
  end
end
