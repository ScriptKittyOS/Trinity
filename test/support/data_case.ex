# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Trinity.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Trinity.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Trinity.DataCase
    end
  end

  setup tags do
    Trinity.DataCase.setup_sandbox(tags)
    # Slice 133: the semantic tier's runtime fault lives outside the database (it is a fact about
    # the node, not the store), so a test that provoked one would otherwise hand it to the next.
    Trinity.Memory.Semantic.clear_fault(:all)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # Slice 023: a live eval holds the connection through several model calls; the sandbox's
    # 120 s ownership timeout disconnected one mid-run, so a test may name its own.
    opts = [shared: not tags[:async]]

    opts =
      if t = tags[:ownership_timeout], do: Keyword.put(opts, :ownership_timeout, t), else: opts

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Trinity.Repo, opts)
    # Slice 024: the receipts Repo under the same ownership, so a chain writer started by a
    # test writes inside the test's sandbox and the rows go with it.
    rpid = Ecto.Adapters.SQL.Sandbox.start_owner!(Trinity.Repo.Receipts, opts)

    # SCR-376 and SCR-377: make each sandboxed transaction a writer before it reads anything.
    #
    # `Ecto.Adapters.SQL.Sandbox` begins every test's transaction with an explicit
    # `mode: :transaction`, which `Exqlite.Connection` resolves ahead of the configured
    # `default_transaction_mode: :immediate`, and which is a plain DEFERRED `BEGIN`. So slice 005's
    # fix does not reach the suite: a test that reads and then writes is upgrading, and SQLite
    # answers `SQLITE_BUSY` on an upgrade **without consulting the busy handler**, whatever
    # `busy_timeout` says. Five failures across three tables came from exactly that.
    #
    # A write that is the transaction's *first* statement is not an upgrade, so the handler is
    # consulted and the writer waits instead of failing. That is measured, not assumed:
    # `test/trinity/repo/sqlite_transaction_mode_test.exs` drives two connections through this
    # exact sequence and asserts both the success and that it genuinely contended.
    #
    # `WHERE 1 = 0` touches no row. The table is the repo's **own** migration table, read from its
    # configuration rather than assumed: `Trinity.Repo.Receipts` sets
    # `migration_source: "receipts_schema_migrations"` (config/config.exs), and hard-coding
    # `schema_migrations` here failed every test using this template, not only the ones that touch
    # receipts. The statement is here for the lock it takes, not for the rows it does not change.
    #
    # Cost: measured as negligible, because there is nothing to serialise. Every file using this
    # case template is `async: false` (the only `async: true` occurrence of it is this file's own
    # documentation), so sandboxed tests already run one at a time.
    Enum.each([Trinity.Repo, Trinity.Repo.Receipts], &take_write_lock/1)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(rpid)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
  end

  # SQLite only. Postgres has no SQLITE_BUSY and no upgrade path to guard, so taking a lock there
  # would be a cost with no reason.
  defp take_write_lock(repo) do
    if repo.__adapter__() == Ecto.Adapters.SQLite3 do
      source = repo.config()[:migration_source] || "schema_migrations"
      Ecto.Adapters.SQL.query!(repo, "DELETE FROM #{source} WHERE 1 = 0", [])
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
