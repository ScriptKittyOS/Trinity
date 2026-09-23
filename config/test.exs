# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Slice 020: the test tools, and the toolset the core ones belong to. AC1's one config line
# is the `modules:` entry; a tool module in test/support plus this line is the whole change.
config :trinity, :tools,
  modules: [
    Trinity.TestTools.Echo,
    Trinity.TestTools.Sleep,
    Trinity.TestTools.Crash,
    Trinity.TestTools.Big,
    Trinity.TestTools.WriteNote,
    # Slice 022: the core tools beside the test ones (this key replaces config.exs's list).
    Trinity.Tools.FS.Read,
    Trinity.Tools.FS.Write,
    Trinity.Tools.FS.Edit,
    Trinity.Tools.FS.List,
    Trinity.Tools.FS.Glob,
    Trinity.Tools.FS.Grep,
    Trinity.Tools.Web.Fetch,
    Trinity.Tools.Web.Search,
    # Slice 031: full-text search over past messages.
    Trinity.Tools.SessionSearch,
    # Slice 032: hybrid recall.
    Trinity.Tools.Recall,
    # Slice 040: the skills' progressive disclosure.
    Trinity.Skills.Tools.List,
    Trinity.Skills.Tools.View,
    Trinity.Skills.Tools.File,
    # Slice 041: proposals and learning, staged for approval.
    Trinity.Skills.Tools.Manage,
    Trinity.Skills.Tools.Learn,
    # Slice 030: the always-on memory tiers.
    Trinity.Tools.Memory,
    Trinity.Tools.Shell.Run
  ],
  toolsets: %{
    core: ["echo", "sleep", "crash", "big", "write_note"],
    fs: ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_grep"],
    web: ["web_fetch", "web_search"],
    shell: ["shell"],
    # Slice 031: search over past conversations.
    memory: ["session_search", "recall", "memory"],
    # Slice 040: the skill tools.
    skills: ["skills_list", "skill_view", "skill_file", "skill_manage", "learn"]
  },
  timeout_ms: 2_000

# Slice 022: the web search provider in tests is the fake; the tests' roots are set per test.
config :trinity, :web, search_provider: Trinity.Tools.Web.SearchProvider.Fake

# Slice 021: requests expire fast enough for AC6 to watch, and a session grant lasts an hour.
config :trinity, :permissions, expiry_ms: 1_000, session_grant_ms: 3_600_000

# Slice 012: sessions hibernate and stop quickly in tests so AC8 is observable in seconds.
config :trinity, :sessions, idle_hibernate_ms: 200, idle_stop_ms: 60_000

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
      price: %{input: 1.0, output: 2.0},
      # Slice 023: a small window so a long fake conversation crosses the thresholds (the fourteen
      # tools' schemas alone are about 1,140 estimated tokens of every request).
      context_tokens: 6_000
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
    pool: Ecto.Adapters.SQL.Sandbox,
    # Slice 032: pgvector's `vector` type.
    types: Trinity.Repo.PostgrexTypes,
    # Slice 032: the sandbox shares one connection with every process a test starts, and
    # DBConnection sheds load (refuses checkouts) when the queue stays over `queue_target`
    # for `queue_interval`. The 100-session and 20-writer tests queue that hard on the
    # postgres job's runner, more so once each turn also runs the retriever (runs 35610164189
    # and 35610171809); a queue that is long on purpose should wait, not shed.
    queue_target: 5_000,
    queue_interval: 30_000

  # Slice 024: the receipts Repo shares the Postgres database (its own migrations table).
  config :trinity, Trinity.Repo.Receipts,
    url: System.get_env("DATABASE_URL"),
    pool_size: 10,
    pool: Ecto.Adapters.SQL.Sandbox,
    queue_target: 5_000,
    queue_interval: 30_000
else
  # Slice 050: two connections, not one. At boot the sandbox is still in auto mode and the
  # first long-lived process to query holds a connection until it exits; Oban verifies its
  # migration at start through a raw checkout (`unboxed_run`) and waited 90 s on the one
  # connection (run of 2026-09-22). Every test still shares its owner's single connection
  # with every process it starts (shared mode), so 010's "writers queue on one connection"
  # holds within a test; the second serves the boot-time check alone.
  config :trinity, Trinity.Repo,
    database: Path.expand("../trinity_test.db", __DIR__),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 2,
    queue_target: 5_000,
    queue_interval: 30_000

  config :trinity, Trinity.Repo.Receipts,
    database: Path.expand("../trinity_test_receipts.db", __DIR__),
    pool: Ecto.Adapters.SQL.Sandbox,
    queue_target: 5_000,
    queue_interval: 30_000
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
# Slice 001 line 5. The endpoint serves in :test, on an ephemeral loopback port.
#
# `server: false` was the generator's default and it is right for controller tests, which go
# through the plug pipeline without a socket. It is wrong for the one thing this slice has to
# establish: `Trinity.Smoke` asks the endpoint which port it actually bound, and against a
# non-serving endpoint that question returns `{:error, :no_server_found}`: a red at an
# earlier fault than the claim, which under docs/03's rules of evidence demonstrates nothing.
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

# Slice 024: the receipt signing key and registry for the suite live under the project's
# ignored tmp/, never in the data directory of the machine running the tests.
config :trinity, :receipts, keys_dir: Path.expand("../tmp/test_keys", __DIR__)

# Slice 032: the suite embeds with the deterministic fake; nothing leaves the machine and no
# model is needed.
config :trinity, :memory, embedder: :fake, observer: false

# Slice 040: the suite's skill roots are fixtures; the user root is a directory a test may
# point elsewhere with `Application.put_env` and a rescan.
config :trinity, :skills,
  bundled_dir: Path.expand("../test/support/fixtures/skills/bundled", __DIR__),
  user_dir: Path.expand("../test/support/fixtures/skills/user", __DIR__),
  # Slice 041: staged changes go under a scratch pending root; a test that promotes points
  # user_dir at a temporary directory first.
  pending_dir: Path.join(System.tmp_dir!(), "trinity-test-pending-skills"),
  watch: true,
  index_tokens: 338

# Slice 060: no MCP client boots from rows in the suite (each test starts the clients it
# needs); a short backoff so the reconnect test runs in seconds.
config :trinity, :mcp_boot, false
config :trinity, :mcp_client, backoff_ms: 50, max_backoff_ms: 400, connect_timeout: 5_000

# Slice 050: Oban runs nothing on its own in the suite; each test drives its jobs.
config :trinity, Oban, testing: :manual
# Slice 050: the dashboard route is mounted in the suite so its mount is a test.
config :trinity, :oban_web, true
