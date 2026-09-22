# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Slice 050: Oban's jobs table. `Oban.Migration` picks the adapter's migration (SQLite or
  # Postgres) from the repo, so one file serves both legs (ADR-0002).
  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end
