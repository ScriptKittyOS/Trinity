# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.TransactionModeConfiguredTest do
  @moduledoc """
  Slice 005 AC2: the mode is what the **running repo** reports, not what a config file says.

  A test that read `config/config.exs` would assert that a line exists. This asks the started repo
  for its own configuration, so it fails if an environment override, a later `config/*.exs`, or a
  runtime block puts it back to `:deferred` without anyone noticing.
  """
  use ExUnit.Case, async: true

  @sqlite Ecto.Adapters.SQLite3

  defp adapter, do: Application.get_env(:trinity, :db_adapter)

  for repo <- [Trinity.Repo, Trinity.Repo.Receipts] do
    test "#{inspect(repo)} begins its transactions IMMEDIATE on SQLite" do
      repo = unquote(repo)

      if adapter() == @sqlite do
        assert repo.config()[:default_transaction_mode] == :immediate,
               "#{inspect(repo)} is on #{inspect(repo.config()[:default_transaction_mode] || :deferred)}. " <>
                 "A deferred transaction upgrading to a write under contention is refused without " <>
                 "the busy handler ever being consulted, which is R26"
      else
        # Postgres has neither the option nor the hazard, and asserting its absence is the honest
        # thing to state rather than skipping silently.
        refute repo.config()[:default_transaction_mode],
               "the SQLite transaction mode leaked into the Postgres build"
      end
    end
  end
end
