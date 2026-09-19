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
      desktop: [
        steps: [:assemble, &Burrito.wrap/1],
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
      extra_applications: [:logger, :runtime_tools]
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
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
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
    ]
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
        "credo --strict",
        "sobelow --exit --skip",
        # `cmd` runs it as its own OS process: Hex's tasks are not reliably resolvable from
        # inside an alias after another task has run, and a separate process also gives this
        # step its own exit code rather than one shared with the alias.
        "cmd mix hex.audit",
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
