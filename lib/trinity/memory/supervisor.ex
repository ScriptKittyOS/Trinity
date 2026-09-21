# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Supervisor do
  @moduledoc """
  The memory side's processes (slice 032): the task supervisor the observer runs under, and
  the embedding serving when the local embedder can serve. The serving is started at boot
  when the model is present and on demand after a download (`ensure_embedding/0`); when it
  cannot start, the tier is off and the reason is logged once, and the tree boots.
  """
  use Supervisor

  require Logger

  alias Trinity.Memory.{Embedder, Embedders, Semantic}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [{Task.Supervisor, name: Trinity.Memory.TaskSupervisor}] ++ embedding_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Starts the local serving if the model is present and it is not running; reports the tier's status."
  @spec ensure_embedding() :: :ok | {:error, term()}
  def ensure_embedding do
    case {Embedder.impl(), Process.whereis(Embedders.Bumblebee.serving_name())} do
      {Embedders.Bumblebee, nil} ->
        with {:ok, spec} <- embedding_child(), do: start_child(spec)

      _ ->
        :ok
    end
  end

  defp start_child(spec) do
    case Supervisor.start_child(__MODULE__, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp embedding_children do
    if Embedder.impl() == Embedders.Bumblebee do
      case embedding_child() do
        {:ok, spec} ->
          [spec]

        {:error, reason} ->
          Logger.info("memory: #{Semantic.describe({:off, reason})}")
          []
      end
    else
      []
    end
  end

  defp embedding_child do
    with :ok <- Embedders.Bumblebee.availability(),
         {:ok, serving} <- Embedders.Bumblebee.serving() do
      {:ok,
       Supervisor.child_spec(
         {Nx.Serving,
          serving: serving,
          name: Embedders.Bumblebee.serving_name(),
          batch_size: 32,
          batch_timeout: 50},
         id: Trinity.Memory.Embedding
       )}
    else
      {:off, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
