# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MixProject do
  use Mix.Project

  def project do
    [
      app: :trinity,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # docs/03-conventions.md sets NO absolute coverage threshold: the rule is that a drop of
      # more than three points against the previous slice fails until NOTES.md names the reason.
      # `mix test --cover` defaults to a 90%% gate, which is a different rule than the one this
      # project states, so it is turned off and `mix trinity.coverage` enforces the real one.
      #
      # Corrected at slice 001 line 13. This read `test_coverage: [threshold: 0]`, which is
      # the wrong shape and did nothing at all: Mix reads the threshold from the `:summary`
      # sub-option (`Keyword.get(opts, :summary, true)` then `get_threshold/1`), so a
      # top-level `:threshold` key is ignored and `get_threshold(true)` returns the built-in
      # 90. `mix test --cover` was still exiting 3 on a rule this project does not have, and
      # the comment above it claimed otherwise for the whole of slice 000.
      test_coverage: [summary: [threshold: 0]],
      # Slice 059: calls into beam_mcp are checked by the boundary compiler everywhere;
      # only Trinity.MCP lists BeamMCP among its deps (ADR-0007 decision 4 and 5).
      boundary: [default: [check: [apps: [:beam_mcp]]]],
      releases: releases()
    ]
  end

  # The desktop release. `Burrito.wrap/1` turns the assembled release into one self-extracting
  # binary per target, which is what slice 001 AC1 launches and AC5 measures.
  #
  # The targets are named here, but only `linux_x86_64` is built on this machine: burrito
  # cross-compiles with Zig, and the macOS and Windows targets additionally need signing and,
  # for Windows, 7z. Slice 001 lines 9 and 10 say what a CI runner can and cannot prove for
  # the other two; nothing here claims they were built.
  #
  # Prerequisites measured at slice 001 line 3, both outside hex and both pinned:
  #   * Zig **exactly** 0.16.0: burrito 1.6.0 compares for equality, not a range
  #     (deps/burrito/lib/burrito.ex `@zig_version_expected`). Pinned in `.tool-versions`.
  #   * Rust 1.92.0 for the Tauri shell. Pinned in `rust-toolchain.toml`, not `.tool-versions`
  #     (see NOTES.md deviation D1).
  defp releases do
    [
      # Slice 061: the headless release. The same tree assembled as an ordinary OTP release
      # (no Burrito, no desktop shell), for a server that runs Trinity as an MCP server and
      # the web pages on a bind address it is told (`TRINITY_MODE=headless`, `TRINITY_BIND`,
      # `PORT`; config/runtime.exs). `ci/headless/Containerfile` builds and runs it.
      headless: [
        steps: [:assemble],
        include_executables_for: [:unix],
        applications: exla_release_applications()
      ],
      desktop: [
        steps: [:assemble, &Burrito.wrap/1],
        # Slice 032: exla in the release, loaded and not started (see `exla_deps/0`); on a
        # Windows host it is not declared at all.
        applications: exla_release_applications(),
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Trinity.Application, []},
      # Slice 024: :sasl for :alarm_handler, the OTP alarm a signer that cannot sign raises
      # (Trinity.Receipts.Alarm), so the failure sounds outside the receipt stream.
      extra_applications: [:logger, :runtime_tools, :sasl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, gate: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  #
  # `credo_checks/` holds this project's own Credo checks. They `use Credo.Check`, and `credo`
  # is `only: [:dev, :test]`, so a check under `lib/` makes `MIX_ENV=prod mix compile` fail on
  # a module Credo cannot load. Measured at slice 001 line 3: the first `MIX_ENV=prod mix
  # release` stopped there, before it reached anything about releases.
  defp elixirc_paths(:test), do: ["lib", "test/support", "credo_checks"]
  defp elixirc_paths(:dev), do: ["lib", "credo_checks"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # Slice 032: EXLA is the local embedder's backend and has no Windows build (xla 0.10.0
  # ships archives for Linux and macOS, x86_64 and aarch64, none for Windows, and building
  # XLA from source needs Bazel), so a Windows host does not declare it: the tree compiles
  # there, `Trinity.Memory.Embedders.Bumblebee.availability/0` answers
  # `{:off, :no_local_backend}`, and the semantic tier is off until a Windows backend exists
  # (NOTES decision 3). The lock file carries exla either way; `mix deps.get` leaves an
  # undeclared lock entry alone.
  #
  # `runtime: false`: exla is compiled and on the code path but not in this application's
  # `applications`, so nothing starts it at boot; the release carries it in `:load` mode
  # (`exla_release_applications/0`, which Mix accepts only because no application in the
  # release depends on it) and `Trinity.Memory.Embedders.Bumblebee.exla/0` starts it on
  # demand. Its start loads the NIF, and in Burrito's musl ERTS on Linux that load fails
  # (`__libc_single_threaded: symbol not found`, package run 35600216451); started at boot
  # it took the whole release down, started on demand it is the tier's reason.
  defp exla_release_applications do
    case :os.type() do
      {:win32, _} -> []
      _ -> [exla: :load]
    end
  end

  defp exla_deps do
    case :os.type() do
      {:win32, _} -> []
      _ -> [{:exla, "~> 0.13.1", runtime: false}]
    end
  end

  defp deps do
    exla_deps() ++
      [
        {:phoenix, "~> 1.8.13"},
        {:phoenix_ecto, "~> 4.5"},
        {:ecto_sql, "~> 3.13"},
        {:ecto_sqlite3, ">= 0.0.0"},
        # Slice 010: the CI-tested alternative behind TRINITY_DB=postgres (docs/adr/0002).
        # Optional so the standalone desktop build carries no Postgres driver; the CI matrix
        # job compiles with the variable set and proves the migrations on both.
        {:postgrex, ">= 0.0.0", optional: true},
        # Slice 011: the provider layer behind Trinity.LLM (docs/adr/0003). What it brings into
        # mix.lock is counted in the slice's NOTES.md, because the desktop binary carries it.
        {:req_llm, "~> 1.22"},
        # Slice 013: the chat's markdown renderer, behind TrinityWeb.Markdown. Chosen by the
        # measurement in the slice's NOTES.md; it brings a Rust NIF (mdex_native), precompiled.
        {:mdex, "~> 0.13"},
        # Slice 020: JSON Schema validation of tool arguments (Trinity.Tools.Schema). Already in
        # the lock through req_llm; direct because a module of ours calls it (ADR-0009).
        {:jsv, "~> 0.23"},
        # Slice 021: RFC 8785 canonical JSON under every approval fingerprint (docs/07). Chosen
        # by the measurement in the slice's NOTES.md; the RFC's vector is a test in the tree.
        {:jcs, "~> 0.2"},
        # Slice 022: HTML to text for web_fetch (Trinity.Tools.Web.Fetch).
        {:floki, "~> 0.38"},
        # Slice 032: local embeddings (Trinity.Memory.Embedders.Bumblebee). The 0.13 line of nx
        # and exla is what bumblebee 0.7.1 accepts (nx 1.0.0 shipped 2026-09-10 and bumblebee has
        # no release for it at G1); measured for bundle size and latency in the slice's NOTES.md.
        {:nx, "~> 0.13.1"},
        {:bumblebee, "~> 0.7.1"},
        # Slice 032: vectors on the Postgres job (Trinity.Memory.VectorStores.Pgvector).
        {:pgvector, "~> 0.4.1"},
        # Slice 040: SKILL.md frontmatter (Trinity.Skills.Parser) and the skill roots' watcher
        # (Trinity.Skills.Watcher); both were in the lock already as transitive dependencies.
        {:yaml_elixir, "~> 2.12"},
        {:file_system, "~> 1.1"},
        # Slice 059: the MCP server core (ADR-0007 decision 5), reached only through the
        # Trinity.MCP boundary; the slice measures its gap, 060 and 061 build on it.
        {:beam_mcp, "~> 0.9"},
        # Slice 050: durable scheduled work. Oban's Lite engine on SQLite, the Basic engine on
        # Postgres; Oban Web is the dashboard, Apache-2.0 on hex since its 2.12 line.
        {:oban, "~> 2.24"},
        {:oban_web, "~> 2.13"},
        # Slice 062: JWT validation and issuance (JWK, JWS, JWKS) over OTP's crypto.
        {:jose, "~> 1.11"},
        # Slice 013 (owner decision, 2026-09-20): the linux package builds mdex's NIF from
        # source for musl (MDEX_NATIVE_BUILD=1 and TRINITY_NIF_TARGET in config/config.exs),
        # because neither precompiled artifact loads in Burrito's musl ERTS (NOTES finding 13).
        # rustler_precompiled needs Rustler present to run that build; build time only.
        {:rustler, "~> 0.38", runtime: false},
        {:phoenix_html, "~> 4.1"},
        {:phoenix_live_reload, "~> 1.2", only: :dev},
        {:phoenix_live_view, "~> 1.2.0"},
        {:lazy_html, ">= 0.1.0", only: :test},
        {:phoenix_live_dashboard, "~> 0.8.3"},
        {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
        {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
        {:heroicons,
         github: "tailwindlabs/heroicons",
         tag: "v2.2.0",
         sparse: "optimized",
         app: false,
         compile: false,
         depth: 1},
        {:daisyui,
         github: "saadeghi/daisyui",
         tag: "v5.5.20",
         sparse: "packages/bundle",
         app: false,
         compile: false,
         depth: 1},
        {:telemetry_metrics, "~> 1.0"},
        {:telemetry_poller, "~> 1.0"},
        {:gettext, "~> 1.0"},
        {:jason, "~> 1.2"},
        {:dns_cluster, "~> 0.2.0"},
        {:bandit, "~> 1.5"},
        # Slice 000: the gate's own tooling. Nothing else yet.
        {:boundary, "~> 0.10", runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mox, "~> 1.2", only: :test},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
        {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.38", only: :dev, runtime: false},
        {:nimble_options, "~> 1.1"},
        # Slice 001 line 1, arm (a) recorded `only: :dev`. **Corrected at G4**, and the reason is
        # the shell, not the tooling: `ExTauri.ShutdownManager` is the sidecar's heartbeat, the
        # Rust window's only way to tell the BEAM it has closed, so it has to exist in the
        # binary that ships, and a `:dev`-only dependency does not. `mix ex_tauri.install` adds
        # that child unconditionally, which is why the generator's output could not start under
        # MIX_ENV=test or MIX_ENV=prod. Recorded as deviation D7 in NOTES.md.
        {:ex_tauri, "~> 0.2"},
        # Slice 001 line 3. `ex_tauri` already depends on burrito, but only in :dev, and
        # `&Burrito.wrap/1` is a release step that runs under MIX_ENV=prod. Declared directly so
        # the module exists in the environment that calls it.
        {:burrito, "~> 1.6"}
      ] ++ posix_deps()
  end

  # Slice 022: the shell tool's process wrapper is a C port built with elixir_make (fork,
  # exec, SIGTERM then SIGKILL, cgroups), and it does not build on Windows. Declared only on
  # a Unix host, the way postgrex is declared only under TRINITY_DB=postgres: the lock keeps
  # the entry, the Windows package never compiles it, and the shell tool answers
  # available?/0 false there (slice 022 NOTES.md, the Windows decision).
  defp posix_deps do
    case :os.type() do
      {:unix, _} -> [{:muontrap, "~> 2.0"}]
      _ -> []
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind trinity", "esbuild trinity"],
      # `compile` first, added at slice 001 after CI caught it. Phoenix 1.8 writes colocated
      # hook and CSS files under `_build/<env>/phoenix-colocated` during compilation, and
      # `assets/css/app.css` imports `phoenix-colocated/trinity/colocated.css`. Without a
      # compile the import cannot resolve, so this alias worked on any machine that had
      # already built and failed on every clean checkout:
      #
      #   Error: Can't resolve 'phoenix-colocated/trinity/colocated.css' in '.../assets/css'
      #
      # `assets.build` above already leads with `compile` for the same reason; this one did
      # not, and the difference only shows on a tree that has never been compiled.
      "assets.deploy": [
        "compile",
        "tailwind trinity --minify",
        "esbuild trinity --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # The quality gate. `mix gate` must exit 0 before every commit (CLAUDE.md section 2).
      #
      # The compile step MUST carry --warnings-as-errors. Measured at slice 000 G1: boundary
      # reports violations as warnings, so without that flag a boundary violation exits 0 and
      # the architecture rules in docs/01 become advisory. test/gate_alias_test.exs asserts the
      # flag is present, so removing it fails the gate.
      gate: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        # The release half, added after slice 062: MIX_ENV=test says nothing about what ships.
        # `Plug.Builder` escapes a plug's `init/1` result at compile time under prod, so a
        # closure in those options broke the release while every gate stayed green, and the
        # three-OS `package` workflow only found it at the tag, after approval (062 NOTES, F5).
        # The script compiles prod, assembles the headless release and evaluates its runtime
        # config, which is the only thing in the gate that executes runtime.exs's prod branch.
        # `cmd`, like the two steps below: its own OS process and its own exit code.
        # `env ERL_AFLAGS=` for the same reason `hex.audit` below carries it: on the FIPS leg
        # this step runs outside FIPS mode. Compiling prod builds the dependencies in that
        # environment, and `tokenizers` fetches a precompiled NIF over TLS, which OTP's ssl
        # cannot do in the mode (docs/fips-leg.md, finding 1: the same HelloRetryRequest
        # problem that stops Hex reaching hex.pm). Whether the tree compiles for release is not
        # a FIPS property, so measuring it outside the mode loses nothing; 024's FIPS
        # properties are measured by `mix test --trace test/fips`, which stays in the mode.
        "cmd env ERL_AFLAGS= ./scripts/prod_check.sh",
        "credo --strict",
        "sobelow --exit --skip",
        # `cmd` runs it as its own OS process: Hex's tasks are not reliably resolvable from
        # inside an alias after another task has run, and a separate process also gives this
        # step its own exit code rather than one shared with the alias.
        #
        # Slice 003: the process runs with ERL_AFLAGS cleared, so that on the FIPS leg this one
        # step runs outside FIPS mode. Hex 2.5.1 offers TLS 1.0 and 1.1 beside 1.2 (its
        # lib/hex/http/ssl.ex hardcodes the three) and ssl in the mode refuses the set with
        # insufficient_crypto_support, so the audit cannot reach hex.pm in the mode; the audit
        # is a registry lookup, not a property the leg measures (docs/fips-leg.md, finding 1).
        # Elsewhere the variable is unset and clearing it changes nothing.
        "cmd env ERL_AFLAGS= mix hex.audit",
        "deps.audit",
        "versions.verify",
        "versions.gen --check",
        "trinity.version_form",
        "trinity.names",
        "trinity.secrets.scan",
        "trinity.reuse",
        "test",
        "trinity.coverage",
        # The plan's own consistency, as the gate's final step rather than a second command
        # with a second exit code. Added at slice 001 G4, for a mistake made three times in
        # this slice: `mix gate` and `scripts/plan_check.sh` were run as a pair, the gate's
        # `exit=0` was read, and `plan_check exit=1` on the line below it was not: twice
        # reaching the remote. Two results printed and one read is a reporting failure the
        # tooling can remove, so it is removed: **one command, one exit code.**
        #
        # `cmd` runs it as its own OS process, the same reason `hex.audit` uses it: the step
        # gets its own exit code rather than sharing the alias's.
        "cmd ./scripts/plan_check.sh"
      ]
    ]
  end
end
