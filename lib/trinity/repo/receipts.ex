# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Receipts do
  @moduledoc """
  The slot for a second database file, reserved at slice 010 and unused until slice 024.

  Declared so that the receipts chain can live in its own SQLite file with its own
  `synchronous` setting (`:full`, if an auditor wants the last committed receipt durable
  across power loss) without moving the primary database later. Not started by the
  application, not in `:ecto_repos`, and no migration targets it at this slice. Slice 024
  configures and starts it; until then any call here fails because the repo is not running,
  which is the intended state.
  """

  use Ecto.Repo,
    otp_app: :trinity,
    adapter: Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)
end
