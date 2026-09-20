# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Receipts do
  @moduledoc """
  The receipts chain's own database: reserved at slice 010, configured and started at slice
  024 (docs/adr/0013).

  Its own SQLite file (`receipts.db` beside the primary; `Trinity.Paths.receipts_database_path/0`)
  with `synchronous: :full`, so the last committed receipt survives power loss, without
  slowing the primary; its own migrations under `priv/repo_receipts`; on Postgres the same
  database as the primary with its own `receipts_schema_migrations` table. `Trinity.Receipts`
  is the only context that reads and writes here, and `Trinity.Receipts.ChainWriter` the only
  process that inserts (the census test).
  """

  use Ecto.Repo,
    otp_app: :trinity,
    adapter: Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)
end
