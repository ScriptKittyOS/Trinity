# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Application do
  # The application supervises processes from both boundaries, so it is its own top-level
  # boundary rather than a member of Trinity. Without this, starting the endpoint reads as
  # Trinity depending on TrinityWeb, which docs/01 forbids.
  # Trinity.Smoke is its own top-level boundary: it is the `--smoke` boot path and has to ask
  # TrinityWeb.Endpoint what port it bound, which Trinity (deps: []) may not do. Adding it here
  # is what lets the child list mention it.
  use Boundary, top_level?: true, deps: [Trinity, TrinityWeb, Trinity.Smoke], exports: []

  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  #
  # Slice 001 line 5: the child list ends with `Trinity.Smoke.children/1`, which is one
  # supervised Task when the process was launched with `--smoke` and nothing otherwise. It
  # goes after the endpoint because it asks the endpoint which port it bound.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      desktop_children() ++
        [
          TrinityWeb.Telemetry,
          # Slice 010: one node per data directory. Before the Repo, so a refused boot has
          # opened no database file; the reason names the holder's OS pid and mode.
          {Trinity.DataDir.Lock, dir: lock_dir(), mode: mode()},
          Trinity.Repo,
          {Ecto.Migrator,
           repos: Application.fetch_env!(:trinity, :ecto_repos), skip: skip_migrations?()},
          {DNSCluster, query: Application.get_env(:trinity, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Trinity.PubSub},
          # Start to serve requests, typically the last entry
          TrinityWeb.Endpoint
        ] ++ Trinity.Smoke.children(Trinity.Smoke.argv())

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Trinity.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TrinityWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # `ExTauri.ShutdownManager` is the sidecar heartbeat: the Rust window connects to a Unix
  # domain socket and sends a byte every 100 ms, and the BEAM shuts itself down 1500 ms after
  # they stop. It is the mechanism finding F1 is about, and it must run in the packaged binary.
  #
  # Excluded from `:test` only, and at **compile time** rather than by asking whether the
  # module happens to be loaded. A `Code.ensure_loaded?/1` guard would silently ship a binary
  # with no heartbeat if the dependency were ever dropped, and a heartbeat that is absent
  # without saying so is the failure it exists to prevent. `test/desktop_children_test.exs`
  # asserts both halves of this.
  @desktop_children if Mix.env() == :test, do: [], else: [ExTauri.ShutdownManager]

  @doc false
  @spec desktop_children() :: [module()]
  def desktop_children, do: @desktop_children

  # The lock lives in the data directory the database defaults to. A deployment that points
  # DATABASE_PATH elsewhere still locks the data directory, which is the thing two instances
  # would otherwise share; the test environment points it at a temporary directory.
  defp lock_dir do
    Application.get_env(:trinity, Trinity.DataDir.Lock, [])[:dir] ||
      Trinity.Paths.ensure_data_dir()
  end

  # `desktop` unless the process says otherwise; slice 061's headless release sets it.
  defp mode do
    case System.get_env("TRINITY_MODE", "desktop") do
      "headless" -> :headless
      _ -> :desktop
    end
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
