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

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(rpid)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
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
