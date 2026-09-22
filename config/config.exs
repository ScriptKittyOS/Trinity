# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Written by `mix ex_tauri.install`; the reasoning is mine, moved here from config/dev.exs
# when the generator put the same keys in this file. All environments, because
# `ExTauri.ShutdownManager` runs in the packaged binary as well as in development.
#
# `:version` is the **Tauri** version and only its major is consumed:
# `ExTauri.Install.Helpers.extract_cli_version/1` takes the major and installs
# `tauri-cli ^<major>`, which resolved to 2.11.4 on 2026-09-06 (VERSIONS.md carries that row
# with its deriving command). 2.5.1 is ex_tauri's own suggested value, kept so this file does
# not invent a pin the library does not use.
config :ex_tauri, app_name: "Trinity", host: "localhost", port: 4000, version: "2.5.1"

config :trinity,
  # Slice 024: the receipts chain has its own Repo and file (docs/adr/0013, `Trinity.Repo.Receipts`);
  # the migrator and the ecto tasks run over both.
  ecto_repos: [Trinity.Repo, Trinity.Repo.Receipts],
  generators: [timestamp_type: :utc_datetime]

# Slice 024: the receipts Repo keeps its migrations apart from the primary's, and on Postgres,
# where both Repos share one database, its own schema_migrations table.
config :trinity, Trinity.Repo.Receipts,
  priv: "priv/repo_receipts",
  migration_source: "receipts_schema_migrations"

# Slice 010. The database adapter is chosen at compile time: SQLite is primary and the default,
# Postgres is the CI-tested alternative behind TRINITY_DB=postgres (docs/adr/0002). An Ecto
# adapter is fixed in `use Ecto.Repo`, so switching means recompiling, and this file says so
# rather than pretending a runtime variable could do it.
config :trinity,
       :db_adapter,
       (case System.get_env("TRINITY_DB", "sqlite") do
          "sqlite" -> Ecto.Adapters.SQLite3
          "postgres" -> Ecto.Adapters.Postgres
          other -> raise "TRINITY_DB must be sqlite or postgres, got #{inspect(other)}"
        end)

# Slice 013 (owner decision, 2026-09-20): the packaged Linux binary runs on Burrito's musl ERTS,
# in which neither precompiled mdex_native artifact loads (both need glibc's libgcc_s), so the
# linux package builds that NIF from source for the musl target with Zig as the linker
# (NOTES.md finding 14). Three settings travel together, all compile time:
#   MDEX_NATIVE_BUILD=1                                  mdex_native compiles instead of downloading
#   TRINITY_NIF_TARGET=x86_64-unknown-linux-musl         the cargo target, given to Rustler here
#   CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=scripts/zig-cc-musl
# Unset, development and the test gate use the precompiled artifact for the host as before.
nif_target = System.get_env("TRINITY_NIF_TARGET", "")

if nif_target != "" do
  config :mdex_native, MDExNative.Native, target: nif_target
end

# Slice 022: the core tools, every environment, and the toolsets they belong to. A tool is a
# module implementing Trinity.Tools.Tool plus a line here (docs/03). The shell answers
# available?/0 false on Windows and is skipped there with a logged reason.
config :trinity, :tools,
  modules: [
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
    # Slice 032: hybrid recall over semantic memories and past messages.
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
    fs: ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_grep"],
    web: ["web_fetch", "web_search"],
    shell: ["shell"],
    # Slice 031: search over past conversations.
    memory: ["session_search", "recall", "memory"],
    # Slice 040: the skill tools.
    skills: ["skills_list", "skill_view", "skill_file", "skill_manage", "learn"]
  }

# Slice 040: the skill roots. `user_dir:` and `bundled_dir:` default to the data directory's
# `skills` and `priv/skills`; `watch: false` turns the filesystem watchers off (the reindex
# button and `mix trinity.skills.reindex` remain); `index_tokens:` caps the prompt's index.
config :trinity, :skills, watch: true, index_tokens: 338

# Slice 022: the filesystem roots beside the data directory (always a root) and the session's
# working directory. Empty here; config/runtime.exs reads TRINITY_FS_ROOTS (colon-separated).
config :trinity, :fs, roots: []

# Slice 011: the model registry lives in its own file so the live test suite can read it
# without evaluating the environment-specific imports below.
import_config "llm.exs"

# Slice 050: Oban on the app's repo. The engine follows the compile-time adapter (Lite on
# SQLite, Basic on Postgres); the queues are small because the machine's model is one; the
# tick is the scheduler's one Cron entry and the curator its second; the pruner keeps the jobs
# table to a week; the lifeline rescues a job orphaned by a crash. config/test.exs sets
# `testing: :manual` so nothing runs on its own in the suite.
config :trinity, Oban,
  repo: Trinity.Repo,
  engine:
    if(System.get_env("TRINITY_DB", "sqlite") == "postgres",
      do: Oban.Engines.Basic,
      else: Oban.Engines.Lite
    ),
  notifier: Oban.Notifiers.PG,
  queues: [agent_tasks: 1, memory: 2, maintenance: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Trinity.Scheduler.Workers.Tick},
       {"0 3 * * *", Trinity.Memory.Curator}
     ]},
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Slice 010, every environment, SQLite only (the Postgres adapter ignores keys it does not
# know, and the CI matrix proves that). One writer: the pool has exactly one connection, so the
# single-writer rule SQLite imposes is the pool's shape rather than a hope. Each pragma is named
# here rather than inherited from the adapter's default, so a default change upstream is a diff
# here and not a silent behaviour change. `synchronous: :normal` under WAL can lose the last
# transaction on power loss and cannot corrupt; the receipts file (slice 024, its own Repo
# below) decides its own setting. `wal_auto_check_point` is in pages; the 010 stress test
# reports the -wal size after its run so the value can be set from a measurement.
if System.get_env("TRINITY_DB", "sqlite") == "sqlite" do
  config :trinity, Trinity.Repo,
    pool_size: 1,
    journal_mode: :wal,
    synchronous: :normal,
    foreign_keys: :on,
    busy_timeout: 5_000,
    cache_size: -64_000,
    wal_auto_check_point: 1_000

  # Slice 024: the receipts file runs `synchronous: :full`, one fsync per committed receipt,
  # so the last signed receipt is durable across power loss. Measured at 024 G1 on this
  # machine: 274 µs per row at one row per transaction under FULL against 20 µs under NORMAL,
  # far under any effect rate; the primary keeps NORMAL.
  config :trinity, Trinity.Repo.Receipts,
    pool_size: 1,
    journal_mode: :wal,
    synchronous: :full,
    foreign_keys: :on,
    busy_timeout: 5_000,
    cache_size: -16_000,
    wal_auto_check_point: 1_000
end

# Configure the endpoint
config :trinity, TrinityWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TrinityWeb.ErrorHTML, json: TrinityWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Trinity.PubSub,
  live_view: [signing_salt: "HZOW4v9g"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  trinity: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  trinity: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
