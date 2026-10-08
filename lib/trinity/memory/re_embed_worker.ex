# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.ReEmbedWorker do
  @moduledoc """
  An operator's re-tier as a job on the `memory` queue (slice 133), for a running node:
  `Trinity.Memory.Spaces.retier/2` toward the named embedder. Nothing in the tree enqueues it on
  its own: not a boot, not a configuration change, not a failure (D3; AC3 counts these jobs and
  expects none). It exists so an operator can re-tier a node that is serving, and
  `mix trinity.space.retier` runs the same function directly.

  `args`: `%{"embedder" => name}`, a name from `Trinity.Memory.Embedder.names/0`. A re-run
  resumes a space left `building`. `:already_active` is a completed job, not an error.
  """
  use Oban.Worker,
    queue: :memory,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Trinity.Memory.{Embedder, Spaces}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"embedder" => name}}) do
    with {:ok, module} <- Embedder.from_name(name) do
      case Spaces.retier(module) do
        {:ok, _} -> :ok
        {:error, :already_active} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
