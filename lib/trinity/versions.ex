# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Versions do
  @moduledoc """
  The machine-readable pin list — finding M6's single source of truth.

  `VERSIONS.md`'s tables are generated from this module by `mix versions.gen`, so the prose
  cannot drift from the checked data, and `mix versions.verify` compares it against `mix.lock`.
  Neither reads the markdown: those cells hold emoji, footnotes and phrases like "decided by
  Slice 059", and a parser over them breaks on the first edit, which is when it is needed.

  ## The verification mark is derived, not remembered

  A row's ✅ means **its package is in `mix.lock` at this sha**, which `mix versions.gen`
  derives from `Mix.Dep.Lock.read/0`. A row whose package is absent keeps 🔍. The two toolchain
  rows carry ✅ on `.tool-versions` and `elixir --version` instead, since they are not hex
  packages.

  That replaces the old meaning — "someone ran `curl` against hex.pm on some date" — which is
  precisely the unverifiable claim finding B3 caught wrong twice, on the two packages the OTP
  pin rested on.

  `lock: nil` marks a row that is not a single hex package: a toolchain component, an
  undecided choice, or two packages named together. Those are never ✅ by lock membership.

  **Deviation from `SLICE.md`, recorded here and in NOTES.md.** The spec named `versions.exs`,
  a data file. A `.exs` data file has to be evaluated at runtime, and
  `Trinity.Credo.NoEvalOnModelOutput` forbids the whole evaluation family under `lib/`. A
  compiled module carries the same data, needs no evaluation, and is checked by the compiler.
  """

  @type row :: %{name: String.t(), pin: String.t(), lock: String.t() | nil, note: String.t()}
  @type table :: %{title: String.t(), kind: :toolchain | :deps, rows: [row()]}

  @toolchain [
    %{
      name: "Erlang/OTP",
      pin: "**28.5.0.5**",
      lock: nil,
      note:
        "Measured at Slice 000, not read from a README: Burrito 1.6.0's ERTS resolver names one artifact source per target, and 28.5.0.5 is the newest OTP returning 200 on all four (macOS universal, Linux x86_64, Linux aarch64, Windows). 28.5.0.6 is released but its macOS and Linux artifacts are unbuilt (404). OTP 29 is 404 on macOS and both Linux arches. ⚠️ Windows tracks OTP releases immediately while the other three lag a third-party CDN's build queue, so re-probe at every phase boundary. See ADR-0005's second correction."
    },
    %{
      name: "Elixir",
      pin: "**1.20.4-otp-28**",
      lock: nil,
      note:
        "Confirmed at Slice 000: `elixir --version` reports Elixir 1.20.4 on Erlang/OTP 28, erts-16.4.0.5. Built-in type checker is part of the gate. `boundary` 0.10.4 compiles and enforces on this pair, measured at Slice 000 (H7)."
    },
    %{
      name: "asdf",
      pin: "v0.18.0",
      lock: nil,
      note:
        "`.tool-versions` committed in Slice 000. `mise` is absent on the build machine; measured at Slice 000 G1 with `which mise asdf`."
    },
    %{
      name: "Rust + Tauri CLI",
      pin: "stable",
      lock: nil,
      note: "Only needed for desktop slices (001, 100, 101). Not a hex package."
    },
    %{
      name: "Zig",
      pin: "version required by Burrito",
      lock: nil,
      note: "Only for cross-target Burrito builds. Not a hex package."
    }
  ]

  @core [
    %{name: "phoenix", pin: "~> 1.8.13", lock: "phoenix", note: ""},
    %{
      name: "phoenix_live_view",
      pin: "~> 1.2.0",
      lock: "phoenix_live_view",
      note: "1.2 line; earlier 1.2.x flagged vulnerable on hex, do not pin lower."
    },
    %{name: "phoenix_pubsub", pin: "~> 2.1", lock: "phoenix_pubsub", note: ""},
    %{name: "bandit", pin: "~> 1.5", lock: "bandit", note: "HTTP server."},
    %{name: "ecto_sql", pin: "~> 3.13", lock: "ecto_sql", note: ""},
    %{
      name: "ecto_sqlite3",
      pin: ">= 0.0.0",
      lock: "ecto_sqlite3",
      note: "Primary DB. FTS5 available."
    },
    %{
      name: "postgrex + pgvector",
      pin: "optional, ~> 0.3",
      lock: nil,
      note:
        "Secondary DB path. Not in default deps; behind `TRINITY_DB=postgres`. Two packages, so no single lock key."
    },
    %{
      name: "oban",
      pin: "~> 2.24",
      lock: "oban",
      note:
        "Uses `Oban.Engines.Lite` on SQLite. ⚠️ Oban Pro Workflows/Smart engine are Postgres-only. Added at Slice 050."
    },
    %{name: "req", pin: "~> 0.5", lock: "req", note: "HTTP client."},
    %{
      name: "req_llm",
      pin: "~> 1.22",
      lock: "req_llm",
      note:
        "Provider layer (streaming, tools, structured output, usage). ⚠️ The pin was `~> 1.10` against a recorded latest of 1.10.0; the real latest was twelve minors ahead. Check event shapes against the current version at Slice 011, not against this file's prose. Added at Slice 011."
    },
    %{
      name: "MCP library",
      pin: "**decided by Slice 059**",
      lock: nil,
      note:
        "Candidates verified 2026-09-05: **anubis_mcp** 2.0.x (hex updated 2026-08-07, **LGPL-3.0**, spec ≤ 2025-11-25); **fastest_mcp** 0.3.2 (2026-08-28, Apache-2.0, very new, ~400 total downloads); **gen_mcp** 2.0.0 (2026-07-30, server-only stateless + compat plug, MIT). ⚠️ None speaks 2024-11-05, which is obsolete and not a target. Undecided, so no lock key."
    },
    %{
      name: "jido",
      pin: "~> 2.3 (pending ADR-0009)",
      lock: "jido",
      note: "Actions, directives and the effect boundary, if the Slice 012 checkpoint adopts it."
    },
    %{name: "jason", pin: "~> 1.2", lock: "jason", note: ""},
    %{
      name: "boundary",
      pin: "~> 0.10",
      lock: "boundary",
      note:
        "Compile-time module dependency enforcement. Measured at Slice 000: it compiles and enforces on Elixir 1.20.4 / OTP 28, and it reports violations as **warnings**, so it enforces only while `--warnings-as-errors` is on the compile step. ⚠️ No release since 2024-09-25."
    },
    %{
      name: "nimble_options",
      pin: "~> 1.1",
      lock: "nimble_options",
      note: "Config validation for behaviours."
    }
  ]

  @memory [
    %{
      name: "nx, exla",
      pin: "latest stable",
      lock: nil,
      note:
        "Local embeddings. EXLA binary size matters for desktop — measure in 032. Two packages, so no single lock key."
    },
    %{
      name: "bumblebee",
      pin: "~> 0.7",
      lock: "bumblebee",
      note: "`all-MiniLM-L6-v2` embeddings; Whisper later. Added at Slice 032."
    },
    %{
      name: "sqlite_vec",
      pin: "~> 0.1",
      lock: "sqlite_vec",
      note:
        "Vectors in SQLite. Verify the loadable extension works inside the Burrito bundle (Slice 032). ⚠️ Pre-1.0, no release in roughly 22 months, 6,938 downloads all-time. R11's trigger already fires. Decide the fallback before Slice 032 starts."
    },
    %{
      name: "hnswlib",
      pin: "~> 0.1.7",
      lock: "hnswlib",
      note: "⚠️ Pre-1.0. Optional accelerator; not on the critical path."
    }
  ]

  @tools [
    %{
      name: "muontrap",
      pin: "~> 2.0",
      lock: "muontrap",
      note:
        "Shell tool. Linux cgroups optional. ⚠️ The pin was `~> 1.8`, which cannot resolve the current major. A major bump is an API review, not a version bump: re-read the child-kill guarantee against 2.0 before Slice 022. Added at Slice 022."
    },
    %{name: "floki", pin: "~> 0.38", lock: "floki", note: "HTML parsing. Added at Slice 022."},
    %{
      name: "luerl (+ sandbox)",
      pin: "latest",
      lock: nil,
      note: "Slice 110 only. Two packages, so no single lock key."
    },
    %{
      name: "burrito",
      pin: "~> 1.6",
      lock: "burrito",
      note:
        "⚠️ ERTS availability drives the OTP pin, and Slice 000 measured it: only the OTP 28 line is fetchable for macOS and Linux. Corrected 2026-09-05: this row previously read `~> 1.5 / 1.5.0 ✅`; that mark was not measured. Added at Slice 001."
    },
    %{
      name: "ex_tauri",
      pin: "~> 0.2",
      lock: "ex_tauri",
      note:
        "⚠️ Declares `otp_release: \"~> 27.0\"`, and Slice 000's probe refutes the reason it gives: OTP 28 macOS universal returns 200 and OTP 27 returns 404. Whether it runs on the pinned OTP is Slice 001's first measurement. ⚠️ 439 downloads all-time, so the ADR-0004 fallback matrix carries real weight."
    },
    %{
      name: "nostrum",
      pin: "~> 0.10",
      lock: "nostrum",
      note:
        "Discord. ⚠️ No release in roughly 18 months. R11's trigger already fires. Check intents and components against the current gateway before Slice 072."
    },
    %{
      name: "telegex",
      pin: "**not pinned**",
      lock: nil,
      note:
        "Telegram. ⚠️ The latest release on hex is a release candidate, roughly two years old, and this file's own rule forbids pinning an `-rc`. Alternative: ex_gram. Slice 071 decides with the measurement."
    },
    %{
      name: "phoenix_streamdown",
      pin: "**not pinned**",
      lock: nil,
      note:
        "Streaming markdown renderer for LiveView. ⚠️ Pre-release, and this file's own rule forbids pinning an `-rc`; a beta is the same category. Verify at Slice 013; fallback: earmark or mdex with chunk buffering."
    }
  ]

  # Brought in by `mix phx.new` at Slice 000. They are direct dependencies of this project, so
  # they belong in the pin list: `mix versions.verify` reports any direct dep in mix.exs with no
  # row here, which is how this group was found rather than remembered.
  @scaffold [
    %{
      name: "phoenix_ecto",
      pin: "~> 4.5",
      lock: "phoenix_ecto",
      note: "Ecto integration for Phoenix. Scaffold."
    },
    %{name: "phoenix_html", pin: "~> 4.1", lock: "phoenix_html", note: "HTML helpers. Scaffold."},
    %{
      name: "phoenix_live_dashboard",
      pin: "~> 0.8.3",
      lock: "phoenix_live_dashboard",
      note: "Runtime dashboard. Slice 090 surfaces it."
    },
    %{
      name: "phoenix_live_reload",
      pin: "~> 1.2",
      lock: "phoenix_live_reload",
      note: "Dev only. Scaffold."
    },
    %{name: "esbuild", pin: "~> 0.10", lock: "esbuild", note: "JS bundling, dev only. Scaffold."},
    %{
      name: "tailwind",
      pin: "~> 0.5",
      lock: "tailwind",
      note: "CSS, dev only. Scaffold. Slice 013 decides the design language on top of it."
    },
    %{
      name: "heroicons",
      pin: "v2.2.0 (github, sparse)",
      lock: nil,
      note: "Icon set, fetched from git rather than hex, so it has no lock key. Scaffold."
    },
    %{
      name: "daisyui",
      pin: "v5.5.20 (github, sparse)",
      lock: nil,
      note:
        "Component classes, fetched from git rather than hex, so it has no lock key. Scaffold."
    },
    %{name: "gettext", pin: "~> 1.0", lock: "gettext", note: "Translations. Scaffold."},
    %{
      name: "dns_cluster",
      pin: "~> 0.2.0",
      lock: "dns_cluster",
      note: "Node discovery. Unused until a clustered deployment exists."
    },
    %{
      name: "telemetry_metrics",
      pin: "~> 1.0",
      lock: "telemetry_metrics",
      note: "Metric definitions. Slice 090 consumes them."
    },
    %{
      name: "telemetry_poller",
      pin: "~> 1.0",
      lock: "telemetry_poller",
      note: "VM measurements. Slice 090 consumes them."
    }
  ]

  @dev [
    %{
      name: "credo",
      pin: "~> 1.7",
      lock: "credo",
      note: "`--strict` in the gate; hosts the eval-family check."
    },
    %{name: "mox", pin: "~> 1.2", lock: "mox", note: "Mocks for every behaviour."},
    %{name: "mix_audit", pin: "~> 2.1", lock: "mix_audit", note: "`mix deps.audit`."},
    %{
      name: "sobelow",
      pin: "~> 0.15",
      lock: "sobelow",
      note:
        "Phoenix security lint. Blocking in the gate with a committed `--skip` list (M5). ⚠️ Its skip fingerprint embeds the file AND line, so an edit above a finding invalidates the skip; reasons live in `.sobelow-skips.reasons`."
    },
    %{name: "ex_doc", pin: "~> 0.38", lock: "ex_doc", note: "Docs."},
    %{name: "lazy_html", pin: "(transitive via LiveView test)", lock: "lazy_html", note: ""}
  ]

  @doc "Toolchain pins: the things `.tool-versions` fixes. Never hex packages."
  @spec toolchain() :: [row()]
  def toolchain, do: @toolchain

  @doc "Dependency pins that `mix.lock` must satisfy once the slice that adds them has run."
  @spec deps() :: [row()]
  def deps, do: @core ++ @scaffold ++ @memory ++ @tools ++ @dev

  @doc """
  Every table `VERSIONS.md` renders, in order.

  `:toolchain` rows are marked from `.tool-versions`; `:deps` rows are marked from `mix.lock`.
  """
  @spec tables() :: [table()]
  def tables do
    [
      %{title: "Toolchain, pinned in `.tool-versions`", kind: :toolchain, rows: @toolchain},
      %{title: "Core libraries", kind: :deps, rows: @core},
      %{title: "Phoenix scaffold, added at slice 000", kind: :deps, rows: @scaffold},
      %{title: "Memory and ML", kind: :deps, rows: @memory},
      %{title: "Tools, sandbox and desktop", kind: :deps, rows: @tools},
      %{title: "Dev and quality", kind: :deps, rows: @dev}
    ]
  end
end
