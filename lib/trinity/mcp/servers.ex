# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Servers do
  @moduledoc """
  The configured servers (slice 060): the `mcp_servers` rows and the clients that run for
  them. Writing a row starts or stops its client to match `enabled`; removing one stops it.
  The page (`/mcp`) reads `status/0`, which joins each row to its client's health.
  """
  import Ecto.Query, only: [from: 2]

  alias Trinity.MCP.{Client, ServerConfig, Supervisor}
  alias Trinity.Repo

  @doc "The rows, by name; `enabled: true` for the enabled ones."
  @spec list(keyword()) :: [ServerConfig.t()]
  def list(opts \\ []) do
    query = from(s in ServerConfig, order_by: s.name)

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> from(s in query, where: s.enabled == ^enabled)
      end

    Repo.all(query)
  end

  @doc "A row by id."
  @spec get(String.t()) :: ServerConfig.t() | nil
  def get(id), do: Repo.get(ServerConfig, id)

  @doc "A row by name."
  @spec get_by_name(String.t()) :: ServerConfig.t() | nil
  def get_by_name(name), do: Repo.get_by(ServerConfig, name: name)

  @doc "Creates a row and, when enabled, starts its client."
  @spec create(map()) :: {:ok, ServerConfig.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, config} <- %ServerConfig{} |> ServerConfig.changeset(attrs) |> Repo.insert() do
      if config.enabled, do: start(config)
      {:ok, config}
    end
  end

  @doc "Updates a row; the client is restarted on a change, or stopped when disabled."
  @spec update(ServerConfig.t(), map()) :: {:ok, ServerConfig.t()} | {:error, Ecto.Changeset.t()}
  def update(%ServerConfig{} = config, attrs) do
    with {:ok, updated} <- config |> ServerConfig.changeset(attrs) |> Repo.update() do
      Supervisor.stop_client(config.name)
      if updated.enabled, do: start(updated)
      {:ok, updated}
    end
  end

  @doc "Removes a row and stops its client."
  @spec delete(ServerConfig.t()) :: {:ok, ServerConfig.t()} | {:error, Ecto.Changeset.t()}
  def delete(%ServerConfig{} = config) do
    Supervisor.stop_client(config.name)
    Repo.delete(config)
  end

  @doc "Starts the client for a row."
  @spec start(ServerConfig.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%ServerConfig{} = config, opts \\ []), do: Supervisor.start_client(config, opts)

  @doc "Stops the client for a row."
  @spec stop(ServerConfig.t()) :: :ok
  def stop(%ServerConfig{name: name}), do: Supervisor.stop_client(name)

  @doc "Every row joined to its client's health (`nil` when no client runs)."
  @spec status() :: [%{config: ServerConfig.t(), client: map() | nil}]
  def status do
    for config <- list() do
      client =
        case Client.info(config.name) do
          {:ok, info} -> info
          {:error, :not_running} -> nil
        end

      %{config: config, client: client}
    end
  end

  @doc "A changeset for a form."
  @spec change(ServerConfig.t(), map()) :: Ecto.Changeset.t()
  def change(%ServerConfig{} = config, attrs \\ %{}), do: ServerConfig.changeset(config, attrs)
end
