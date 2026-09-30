# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.SandboxTransactionModeTest do
  @moduledoc """
  R26's residual half: `default_transaction_mode: :immediate` does **not** reach a sandboxed test.

  Slice 005 reproduced R26 and demonstrated the fix, deliberately outside the sandbox, because
  "the sandbox wraps each test in one connection's transaction and cannot express two contending
  writers" (`test/trinity/repo/sqlite_transaction_mode_test.exs`). `config/test.exs` then sets
  `default_transaction_mode: :immediate` on both test repos, which reads as though the suite were
  covered too.

  It is not, and this file is here so that sentence cannot quietly stay wrong.

  `Ecto.Adapters.SQL.Sandbox.post_checkout/3` begins the per-test transaction with
  `conn_mod.handle_begin([mode: :transaction] ++ opts, conn_state)`. `Exqlite.Connection` resolves
  the mode as `Keyword.get(options, :mode, state.default_transaction_mode)`, so an explicit
  `:mode` in the options **wins over the configured default**, and `:transaction` maps to a plain
  `BEGIN TRANSACTION`, which is DEFERRED.

  So every sandboxed test runs in a DEFERRED transaction. A test whose first statements read and
  then write is doing exactly what R26 describes: the read makes the transaction a reader, the
  write tries to upgrade, and if another connection has written in between SQLite answers
  `SQLITE_BUSY` **without consulting the busy handler**, so neither the 30 s `busy_timeout` nor
  the `:immediate` setting can help. `Trinity.Gateways.IdentitiesTest` is such a test and has
  failed this way on CI (gate run 36742943477, while the other run on the same commit passed).

  This is a fact about a dependency, so it is asserted against the dependency's source rather than
  described. If an upgrade changes either line, this fails and the reasoning above gets revisited
  instead of rotting.
  """
  use ExUnit.Case, async: true

  @sandbox "deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex"
  @exqlite "deps/exqlite/lib/exqlite/connection.ex"

  test "the sandbox begins its per-test transaction with an explicit mode, and that mode is DEFERRED" do
    sandbox = File.read!(@sandbox)

    assert sandbox =~ "handle_begin([mode: :transaction] ++ opts",
           """
           #{@sandbox} no longer begins the sandbox transaction with `mode: :transaction`.

           That is the line this project's understanding of R26-inside-the-suite rests on. Re-read
           it: if the sandbox now begins IMMEDIATE, or takes the mode from the repo's
           configuration, then `default_transaction_mode: :immediate` in config/test.exs finally
           does reach sandboxed tests, and the moduledoc here and the comment in config/test.exs
           should say so.
           """
  end

  test "an explicit :mode option wins over the configured default_transaction_mode" do
    exqlite = File.read!(@exqlite)

    assert exqlite =~ "Keyword.get(options, :mode, state.default_transaction_mode)",
           """
           #{@exqlite} no longer resolves the transaction mode by preferring an explicit `:mode`
           option over the configured default. If the precedence has reversed, the sandbox's
           `mode: :transaction` no longer overrides `default_transaction_mode: :immediate`.
           """

    # And `:transaction` is the plain BEGIN, not the IMMEDIATE one: the two are separate clauses
    # and only one of them takes the write lock up front.
    assert exqlite =~ ~s|:transaction when transaction_status == :idle ->|
    assert exqlite =~ ~s|handle_transaction(:begin, "BEGIN TRANSACTION", state)|
    assert exqlite =~ ~s|handle_transaction(:begin, "BEGIN IMMEDIATE TRANSACTION", state)|
  end
end
