# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Versions do
  @moduledoc """
  The machine-readable pin list: finding M6's single source of truth.

  `VERSIONS.md`'s tables are generated from this module by `mix versions.gen`, so the prose
  cannot drift from the checked data, and `mix versions.verify` compares it against `mix.lock`.
  Neither reads the markdown: those cells hold emoji, footnotes and phrases like "decided by
  Slice 059", and a parser over them breaks on the first edit, which is when it is needed.

  ## The verification mark is derived, not remembered

  A row's ✅ means **its package is in `mix.lock` at this sha**, which `mix versions.gen`
  derives from `Mix.Dep.Lock.read/0`. A row whose package is absent keeps 🔍. The two toolchain
  rows carry ✅ on `.tool-versions` and `elixir --version` instead, since they are not hex
  packages.

  That replaces the old meaning, "someone ran `curl` against hex.pm on some date", which is
  precisely the unverifiable claim finding B3 caught wrong twice, on the two packages the OTP
  pin rested on.

  `lock: nil` marks a row that is not a single hex package: a toolchain component, an
  undecided choice, or two packages named together. Those are never ✅ by lock membership.

  ## Toolchain rows name their own pin file, added at Slice 001 line 3

  Until this slice every toolchain row was marked `✅ .tool-versions` from a hardcoded clause,
  including Rust and Zig, which that file did not carry. Each toolchain row now states its
  `:from`:

    * `{:file, path, needle}`: the pin lives in a file in the tree. `mix versions.gen` reads
      that file and marks the row from what it finds, so a row naming a file that stops
      carrying its pin fails the gate rather than keeping a stale ✅.
    * `{:command, cmd}`: no file in the tree carries this pin, and only running `cmd` can
      answer. Marked 📐, never ✅, because nothing at this sha verifies it; the measurement
      lives in the slice's PROOF.md with its exit code.

  `VersionsToolchainMarkTest` is the enforcer, and it was committed failing first.

  **Deviation from `SLICE.md`, recorded here and in NOTES.md.** The spec named `versions.exs`,
  a data file. A `.exs` data file has to be evaluated at runtime, and
  `Trinity.Credo.NoEvalOnModelOutput` forbids the whole evaluation family under `lib/`. A
  compiled module carries the same data, needs no evaluation, and is checked by the compiler.
  """

  @type source :: {:file, Path.t(), String.t()} | {:command, String.t()}
  @type row :: %{
          required(:name) => String.t(),
          required(:pin) => String.t(),
          required(:lock) => String.t() | nil,
          required(:note) => String.t(),
          optional(:from) => source()
        }
  @type table :: %{title: String.t(), kind: :toolchain | :deps, rows: [row()]}

  @toolchain [
    %{
      name: "Erlang/OTP",
      pin: "**28.5.0.5**",
      lock: nil,
      from: {:file, ".tool-versions", "erlang 28.5.0.5"},
      note:
        "Measured at Slice 000, not read from a README: Burrito 1.6.0's ERTS resolver names one artifact source per target, and 28.5.0.5 is the newest OTP returning 200 on all four (macOS universal, Linux x86_64, Linux aarch64, Windows). 28.5.0.6 is released but its macOS and Linux artifacts are unbuilt (404). OTP 29 is 404 on macOS and both Linux arches. ⚠️ Windows tracks OTP releases immediately while the other three lag a third-party CDN's build queue, so re-probe at every phase boundary. See ADR-0005's second correction."
    },
    %{
      name: "Elixir",
      pin: "**1.20.4-otp-28**",
      lock: nil,
      from: {:file, ".tool-versions", "elixir 1.20.4-otp-28"},
      note:
        "Confirmed at Slice 000: `elixir --version` reports Elixir 1.20.4 on Erlang/OTP 28, erts-16.4.0.5. Built-in type checker is part of the gate. `boundary` 0.10.4 compiles and enforces on this pair, measured at Slice 000 (H7)."
    },
    %{
      name: "asdf",
      pin: "v0.18.0",
      lock: nil,
      from: {:command, "asdf --version"},
      note:
        "`.tool-versions` committed in Slice 000. `mise` is absent on the build machine; measured at Slice 000 G1 with `which mise asdf`. asdf cannot pin itself, so this row is a command, not a file. ⚠️ Measured at Slice 001 line 3: asdf does **not** fail on a tool it has no plugin for, a `rust 1.92.0` line is omitted from `asdf current` and `asdf install` still exits 0. A pin file entry is only a pin where a plugin exists."
    },
    %{
      name: "Rust",
      pin: "**1.92.0**",
      lock: nil,
      from: {:file, "rust-toolchain.toml", "1.92.0"},
      note:
        "Measured at Slice 001 line 3: `rustc --version` reports 1.92.0 (ded5c06cf 2025-12-08), exit 0. Pinned in `rust-toolchain.toml`, **not** `.tool-versions`: `asdf` here has no rust plugin and silently ignores a rust line, whereas `rustup show active-toolchain` reports this file as an override. See NOTES.md deviation D1. Corrected 2026-09-06: this row previously read `Rust + Tauri CLI | stable | ✅ .tool-versions`, which named a file carrying neither."
    },
    %{
      name: "Tauri CLI",
      pin: "**2.11.4**",
      lock: nil,
      from: {:command, "_build/_tauri/bin/cargo-tauri tauri --version"},
      note:
        "Measured at Slice 001 line 3. Not on `PATH` and not pinned by any file in the tree: `ex_tauri` provisions it with `cargo install tauri-cli --version ^2 --root .` inside `_build/_tauri`, which is gitignored, so `cargo tauri --version` exits 101 on a fresh machine. 📐 rather than ✅ because nothing at this sha verifies it. The `^2` floats; 2.11.4 is what it resolved to on 2026-09-06."
    },
    %{
      name: "Zig",
      pin: "**0.16.0**",
      lock: nil,
      from: {:file, ".tool-versions", "zig 0.16.0"},
      note:
        "Measured at Slice 001 line 3: burrito 1.6.0 compares Zig for **equality**, not a range (`@zig_version_expected` in `deps/burrito/lib/burrito.ex`), and exits 1 on any other version. `zig version` reports 0.16.0, exit 0. Installed through the asdf zig plugin, added this slice. Corrected 2026-09-06: this row previously read `version required by Burrito | ✅ .tool-versions` and that file carried no zig line."
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
      name: "postgrex",
      pin: ">= 0.0.0 (optional)",
      lock: "postgrex",
      note:
        "Secondary DB driver, `optional: true` so the desktop build carries none of it; compiled in only under `TRINITY_DB=postgres`, which the CI job proves. Added at Slice 010. Was one row with pgvector; pgvector keeps its own row below."
    },
    %{
      name: "pgvector",
      pin: "optional, ~> 0.3",
      lock: "pgvector",
      note:
        "Vectors on the Postgres path. Not yet a dependency; Slice 032 decides. Split from the postgrex row at Slice 010."
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
      name: "beam_mcp",
      pin: "~> 0.8",
      lock: "beam_mcp",
      note:
        "MCP server core, Apache-2.0, ADR-0007 decision 5 (owner decision 2026-09-08, recorded 2026-09-20). 0.8.0 on hex.pm, standing before 1.0.0. Server side only: the client, MRTR and OAuth are Trinity's, above it. Added at Slice 059. The earlier candidate list (anubis_mcp, fastest_mcp, gen_mcp) is history."
    },
    %{
      name: "jido",
      pin: "not used (ADR-0009, decided 2026-09-20)",
      lock: nil,
      note:
        "Measured at the Slice 012 checkpoint and not adopted: the agent runtime duplicates PubSub, Oban and the gateways and adds a second tool executor; the action shape is written in-tree at Slice 020 with `jsv` for its schemas. The row stays so the decision is visible where a reader would look for the package."
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
        "Local embeddings. EXLA binary size matters for desktop: measure in 032. Two packages, so no single lock key."
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
        "The shell tool's process wrapper (`Trinity.Tools.Shell.Run`, Slice 022): a C port, SIGTERM then SIGKILL, the child dies with the port. Read against 2.0.0 at Slice 022: `cmd/3` takes `:timeout` (SIGTERM at expiry, `:timeout` as the status), `:delay_to_sigkill`, `:cd`, `:env`, optional cgroup v2 limits. ⚠️ POSIX only: declared in mix.exs on a Unix host alone; the shell tool is unavailable on Windows (NOTES.md, the Windows decision)."
    },
    %{
      name: "floki",
      pin: "~> 0.38",
      lock: "floki",
      note: "HTML to text for `web_fetch` (Slice 022): script, style, nav, header, footer and aside dropped, the body's text taken."
    },
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
      pin: "not used (measured at Slice 013, 2026-09-20)",
      lock: nil,
      note:
        "Streaming markdown renderer for LiveView. Measured at Slice 013: 1.0.0-beta.4 (2026-05-03) was still the latest release with no stable behind it, and this file's own rule forbids a pre-release. It is 801 lines over `mdex`, whose own `streaming: true` option completes fragments; the rest is a rendering rule Slice 013 keeps anyway. The row stays so the decision is visible where a reader would look for the package."
    },
    %{
      name: "mdex",
      pin: "~> 0.13",
      lock: "mdex",
      note:
        "Markdown renderer for the chat (`TrinityWeb.Markdown`), streaming fragments completed by its `streaming: true` option, raw HTML omitted (`unsafe: false`) and the default sanitizer on top. Added at Slice 013 after the measurement in its NOTES.md: `earmark` 1.4.49 is retired on hex with an open XSS advisory (EEF-CVE-2026-48591), which the gate refuses. ⚠️ A Rust NIF (`mdex_native`): the first in the bundle. Measured at Slice 013 (NOTES finding 13): neither precompiled artifact loads in Burrito's musl ERTS on Linux, so the linux package builds it from source for musl with Zig as the linker (`rustler` below, `scripts/zig-cc-musl`, the three settings in config/config.exs); macOS and Windows load the precompiled artifact. The `--smoke` path prints whether it rendered, and the `package` workflow reads that line on every target."
    },
    %{
      name: "jsv",
      pin: "~> 0.23",
      lock: "jsv",
      note:
        "JSON Schema (2020-12) validation of tool arguments in `Trinity.Tools.Schema`, with `cast: false` so a malformed call is refused and never repaired (docs/07). Was transitive through req_llm; direct since Slice 020 because a module of ours calls it (ADR-0009: Trinity's own tool behaviour, jsv for its schemas)."
    },
    %{
      name: "jcs",
      pin: "~> 0.2",
      lock: "jcs",
      note:
        "RFC 8785 canonical JSON, under every approval fingerprint (`Trinity.Permissions.Fingerprint`, Slice 021) and, at 024, under the receipts' signed payload. Chosen at Slice 021: it matches the RFC's own example vector byte for byte on this OTP, and `test/trinity/permissions/fingerprint_test.exs` keeps that vector so a release that stops matching fails the gate. ⚠️ Pre-1.0, released 2025-03-31 with nothing since (R11's trigger). The alternative, `rfc8785` 1.0.0, refuses OTP 28 and waits on the OTP pin."
    },
    %{
      name: "rustler",
      pin: "~> 0.38",
      lock: "rustler",
      note:
        "Build time only (`runtime: false`): what `rustler_precompiled` needs to compile `mdex_native` from source when `MDEX_NATIVE_BUILD=1`, which the linux package sets (owner decision 2026-09-20, Slice 013 NOTES finding 14). Nothing in the tree calls it."
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
      %{
        title: "Toolchain: each row names its own pin file or command",
        kind: :toolchain,
        rows: @toolchain
      },
      %{title: "Core libraries", kind: :deps, rows: @core},
      %{title: "Phoenix scaffold, added at slice 000", kind: :deps, rows: @scaffold},
      %{title: "Memory and ML", kind: :deps, rows: @memory},
      %{title: "Tools, sandbox and desktop", kind: :deps, rows: @tools},
      %{title: "Dev and quality", kind: :deps, rows: @dev}
    ]
  end
end
