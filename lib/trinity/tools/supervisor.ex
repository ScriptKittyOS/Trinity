# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Supervisor do
  @moduledoc """
  The tool runtime's tree. Slice 020: the registry and the task supervisor every tool call
  runs under; slice 022 adds the stateful runtimes (a shell, a browser) beside them.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Trinity.Tools.TaskSupervisor},
      # Slice 135: which sessions read a path tagged sensitive, for web_fetch's escalation.
      Trinity.Tools.Taint,
      Trinity.Tools.Registry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
