# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :trinity, Trinity.Repo,
  database: Path.expand("../trinity_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
# Slice 001 line 5. The endpoint serves in :test, on an ephemeral loopback port.
#
# `server: false` was the generator's default and it is right for controller tests, which go
# through the plug pipeline without a socket. It is wrong for the one thing this slice has to
# establish: `Trinity.Smoke` asks the endpoint which port it actually bound, and against a
# non-serving endpoint that question returns `{:error, :no_server_found}`: a red at an
# earlier fault than the claim, which under CLAUDE.md section 8 demonstrates nothing.
#
# `port: 0` is the same ephemeral bind the packaged binary uses, so the test exercises the
# real path rather than a fixed 4002 that a second run or a stray process can take. Nothing
# here reaches the network: `Trinity.NetworkGuard` blocks outbound connections and a loopback
# listen is not one.
config :trinity, TrinityWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: "PAlioLgquSvnIrD4YjwqUt4LEP1x1E5d56Z7KY/QhgmyRUFR9ynpk3oz/hITAYwN",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
