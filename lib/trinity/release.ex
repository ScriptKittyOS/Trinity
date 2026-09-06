# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Release do
  @moduledoc """
  Release-time tasks for the packaged desktop binary.

  A Mix release carries no Mix, so `mix ecto.migrate` does not exist inside the binary that
  slice 001 ships. Migrations run through this module instead, called from the binary's own
  boot path rather than from a shell script, so the packaged app and the development app
  reach the same schema by the same code.

  This module is packaging, not domain code: it starts the repo, runs whatever migrations
  exist, and stops. Slice 000 added no schemas, so on this slice `migrate/0` finds an empty
  migration directory and succeeds, which is the honest state and is recorded as such in
  PROOF.md rather than presented as a migration having run.
  """

  @app :trinity

  @doc """
  Runs every pending migration for every repo in the release, up to the latest version.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls `repo` back to `version`. Present for symmetry; not used by the boot path.
  """
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _fun_return, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: :ok
  defp load_app do
    Application.ensure_loaded(@app)
    :ok
  end
end
