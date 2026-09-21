# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# Slice 032: the Postgres build's Postgrex types with pgvector's `vector` beside the
# defaults, so `memories.embedding_vector` can be bound and read. Defined only when the
# Postgres adapter is compiled in (`TRINITY_DB=postgres`; postgrex is optional and absent
# from the desktop build); `config :trinity, Trinity.Repo, types: Trinity.Repo.PostgrexTypes`
# names it in the same branch of config/runtime.exs and config/test.exs.
if Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3) == Ecto.Adapters.Postgres do
  Postgrex.Types.define(
    Trinity.Repo.PostgrexTypes,
    Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
    []
  )
end
