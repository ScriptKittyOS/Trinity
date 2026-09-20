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
          # Slice 024 (ADR-0010): the authority is selected once, here, before anything that
          # could act; a refused selection stops the boot with its reason.
          Trinity.Authority.Selection,
          Trinity.Repo,
          # Slice 024: the receipts chain's own file (ADR-0013, `Trinity.Repo.Receipts`).
          Trinity.Repo.Receipts,
          {Ecto.Migrator,
           repos: Application.fetch_env!(:trinity, :ecto_repos), skip: skip_migrations?()},
          {DNSCluster, query: Application.get_env(:trinity, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Trinity.PubSub},
          # Slice 011: streams to a pid run under this supervisor, never as bare tasks.
          {Task.Supervisor, name: Trinity.LLM.TaskSupervisor},
          # Slice 012: one session process per conversation, found by id.
          {Registry, keys: :unique, name: Trinity.Registry},
          # Slice 024: the signer and its key, the chain writers, the boot receipt. Before the
          # tools and the sessions, which receipt through it.
          Trinity.Receipts.Supervisor,
          # Slice 024: the boot receipt, once the signer and the authority are known.
          Trinity.Effects.Boot,
          # Slice 020: the tool registry and the task supervisor tool calls run under, before
          # the sessions that call them.
          Trinity.Tools.Supervisor,
          # Slice 021: approval requests and their decisions, with pending rows reloaded.
          Trinity.Permissions.Gate,
          Trinity.Sessions.Supervisor,
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

  # Migrations run at boot everywhere except under Mix, where `mix ecto.migrate` and the test
  # alias own them. The generator's version keyed on RELEASE_NAME, which the release's own
  # `bin/desktop` script exports and the Burrito wrapper does not: it starts `erlexec`
  # directly (deps/burrito/src/erlang_launcher.zig), so the packaged binary never migrated
  # and every table was missing. Latent since slice 010, seen at slice 013 when `/` first
  # read a table: package run 35519205973, "no such table: sessions" on all three operating
  # systems, and the same binary locally answering 200 once RELEASE_NAME was set by hand.
  defp skip_migrations?, do: Code.ensure_loaded?(Mix)
end
