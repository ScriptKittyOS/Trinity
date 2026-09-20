# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Slice 011: the registry in tests is the scripted fake plus a Mox mock; the live tests set
# their own entries from the environment at runtime.
config :trinity, :llm,
  default_model: "fake:chat",
  providers: %{fake: Trinity.LLM.Providers.Fake, mock: Trinity.LLM.ProviderMock},
  retry: [attempts: 3, base_ms: 1],
  models: [
    %{
      id: "fake:chat",
      provider: :fake,
      model: "chat",
      caps: [:stream, :tools, :json],
      price: %{input: 1.0, output: 2.0}
    },
    %{
      id: "fake:embed",
      provider: :fake,
      model: "embed",
      caps: [:embed, {:embed_dim, 8}],
      price: %{input: 0.5, output: 0.0}
    },
    %{
      id: "mock:chat",
      provider: :mock,
      model: "chat",
      caps: [:stream, :tools],
      price: %{input: 0.0, output: 0.0}
    }
  ]

# Slice 010: the data-dir lock takes a temporary directory in tests, so a test run never
# contends with a running Trinity on the same machine, and two test runs at once do contend,
# which is the property under test.
config :trinity, Trinity.DataDir.Lock,
  dir:
    Path.join(System.tmp_dir!(), "trinity-test-lock-#{System.get_env("MIX_TEST_PARTITION", "0")}")

# Slice 010: the pool has one connection (config/config.exs), so the sandbox hands every test
# the same connection and concurrent writers in a test queue on it exactly as they do in
# production. Tests that touch the Repo are not `async: true` for that reason.
if System.get_env("TRINITY_DB") == "postgres" do
  config :trinity, Trinity.Repo,
    url: System.get_env("DATABASE_URL") || raise("TRINITY_DB=postgres needs DATABASE_URL"),
    pool_size: 10,
    pool: Ecto.Adapters.SQL.Sandbox
else
  config :trinity, Trinity.Repo,
    database: Path.expand("../trinity_test.db", __DIR__),
    pool: Ecto.Adapters.SQL.Sandbox
end

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
