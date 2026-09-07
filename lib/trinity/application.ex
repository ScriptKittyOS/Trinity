# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Application do
  # The application supervises processes from both boundaries, so it is its own top-level
  # boundary rather than a member of Trinity. Without this, starting the endpoint reads as
  # Trinity depending on TrinityWeb, which docs/01 forbids.
  # Trinity.Smoke is its own top-level boundary — it is the `--smoke` boot path and has to ask
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
      [
        # Start a worker by calling: Trinity.Worker.start_link(arg)
        # {Trinity.Worker, arg},
        # Start to serve requests, typically the last entry
        ExTauri.ShutdownManager,
        TrinityWeb.Telemetry,
        Trinity.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:trinity, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:trinity, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Trinity.PubSub},
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

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
