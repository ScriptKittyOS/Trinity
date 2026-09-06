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
      test_coverage: [threshold: 0]
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
  defp elixirc_paths(:test), do: ["lib", "test/support"]
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
      {:nimble_options, "~> 1.1"}
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
      "assets.deploy": [
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
        "trinity.coverage"
      ]
    ]
  end
end
