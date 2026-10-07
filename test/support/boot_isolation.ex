# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.BootIsolation do
  @moduledoc """
  Gives a spawned boot its own databases, whichever adapter is compiled in.

  `test/trinity/regulated_boot_node_test.exs` boots Trinity in a separate OS process, because
  `start/2` cannot be re-run in a VM where the application is already up. Such a child needs
  databases that are **not** the suite's own: it writes a boot receipt, and six children appending
  to the chain the suite is using is not isolation.

  Two things make that awkward, and this module exists to hold both in one place.

  **The database is named differently per adapter.** Under SQLite it is a file path; under
  `TRINITY_DB=postgres` it is a name inside a URL. `config/test.exs` fixes either one and derives
  neither from `XDG_DATA_HOME`, so pointing a child at its own data directory does not move its
  database. The config is rewritten here instead, in whichever shape the compiled adapter uses.

  **Migrations do not run in the child.** `Trinity.Application`'s `skip_migrations?/0` is
  `Code.ensure_loaded?(Mix)`, so under `mix run` the `Ecto.Migrator` child is skipped and a fresh
  database would boot with no tables. `isolate!/1` therefore creates the storage and runs the
  migrations itself, before the application starts.

  The sandbox pool is removed as well. A child is a real boot, not a sandboxed test, and nothing
  in it owns a sandbox connection. So is the data-directory lock's pinned path, for the same reason
  the database is renamed: `config/test.exs` fixes it per test partition rather than per process.
  """

  @repos [Trinity.Repo, Trinity.Repo.Receipts]

  @doc """
  Called **in the child**, with `--no-start`, before `Application.ensure_all_started/1`.

  Rewrites both repos' configuration to a database named after `tag`, creates it, and migrates it.
  """
  @spec isolate!(String.t()) :: :ok
  def isolate!(tag) when is_binary(tag) and tag != "" do
    # The data-directory lock is pinned by `config/test.exs` to one path per test partition, so the
    # suite holds it and every child would refuse to boot with `{:data_dir_held, ...}`. Dropping the
    # override returns `Trinity.Application`'s `lock_dir/0` to `Trinity.Paths.ensure_data_dir/0`,
    # which reads `XDG_DATA_HOME` — the variable the caller already sets per case. Under
    # `MIX_ENV=dev` there was no override and this was free; it is the same class of problem as the
    # pinned database, and it belongs here beside it rather than in six call sites.
    Application.delete_env(:trinity, Trinity.DataDir.Lock)

    Enum.each(@repos, fn repo ->
      config = rewrite(repo, tag)
      Application.put_env(:trinity, repo, config)

      # `:already_up` is not an error here: a tag is unique per case, but a retried run of the same
      # case reuses it, and a database that exists is exactly what was wanted.
      _ = repo.__adapter__().storage_up(config)

      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true), pool_size: 2)
    end)
  end

  @doc """
  Called **in the parent**, from `on_exit`, to drop what a child created.

  Matters most under Postgres, where a leaked database outlives the run on a developer's machine.
  Under SQLite the files sit in the case's temporary directory and go with it.
  """
  @spec drop!(String.t()) :: :ok
  def drop!(tag) when is_binary(tag) do
    Enum.each(@repos, fn repo ->
      _ = repo.__adapter__().storage_down(rewrite(repo, tag))
    end)
  end

  @doc "The tag a case uses, unique per case and short enough to be a Postgres database name."
  @spec tag(String.t()) :: String.t()
  def tag(name) do
    "trinity_boot_#{name}_#{System.unique_integer([:positive])}"
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.slice(0, 50)
  end

  defp rewrite(repo, tag) do
    config = Application.get_env(:trinity, repo, [])
    name = "#{tag}_#{repo |> Module.split() |> List.last() |> String.downcase()}"

    config
    # A child is a real boot. Nothing in it owns a sandbox connection.
    |> Keyword.delete(:pool)
    |> name_database(name)
  end

  # Postgres: the database is a name inside a URL. The URL is replaced with explicit keys rather
  # than patched, so there is no second source of truth for the same field.
  defp name_database(config, name) do
    case Keyword.get(config, :url) do
      url when is_binary(url) and url != "" ->
        uri = URI.parse(url)
        {username, password} = userinfo(uri)

        config
        |> Keyword.delete(:url)
        |> Keyword.merge(
          username: username,
          password: password,
          hostname: uri.host || "localhost",
          port: uri.port || 5432,
          database: name
        )

      _ ->
        Keyword.put(config, :database, Path.join(System.tmp_dir!(), name <> ".db"))
    end
  end

  defp userinfo(%URI{userinfo: info}) when is_binary(info) do
    case String.split(info, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, nil}
    end
  end

  defp userinfo(_), do: {"postgres", nil}
end
