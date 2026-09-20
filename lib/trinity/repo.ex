# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo do
  @moduledoc """
  The one writer. Slice 010.

  The adapter is fixed at compile time from `config :trinity, :db_adapter` (SQLite by default,
  Postgres behind `TRINITY_DB=postgres`), because `use Ecto.Repo` takes it as a literal and no
  runtime variable can change it afterwards. On SQLite the pool holds one connection
  (`config/config.exs`), so every write in the node serialises here rather than in
  `busy_timeout`.
  """

  use Ecto.Repo,
    otp_app: :trinity,
    adapter: Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)
end
