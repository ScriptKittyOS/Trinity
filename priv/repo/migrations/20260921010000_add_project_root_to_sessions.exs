# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.AddProjectRootToSessions do
  @moduledoc "Slice 033: the session's project root, the directory its tools work in and AGENTS.md is read from."
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :project_root, :string
    end
  end
end
