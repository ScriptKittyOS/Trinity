# ADR-0005 — Pin OTP to the newest version the packaging chain supports (OTP 28 today)
Status: accepted · Date: 2026-09-05

## Context
"Latest stable" OTP is 29.0.6 (2026-09-01). Burrito ships precompiled ERTS per OTP version; its latest release
notes reference OTP 28.0.2 (Nov 2025). ex_tauri's README states OTP 27 due to Burrito ERTS availability
(possibly outdated). Building our own ERTS for every target is possible (`custom_erts`) but costly.

## Decision
Pin OTP to the latest 28.x patch that Burrito provides an ERTS for. Pin Elixir to the latest 1.20.x compatible
with it. Re-check at Slice 001 and at every phase boundary; move to OTP 29 as soon as Burrito publishes
OTP 29 ERTS for macOS/Linux/Windows.

## Consequences
- We are one major behind the runtime frontier by choice; nothing in the plan needs OTP 29 features.
- `VERSIONS.md` records the exact patch after Slice 000 verifies it.

## Correction, appended 2026-09-05
Supersedes nothing in the Context or Decision above; it names the measurement those rested on.

Both inputs to the Context were unmeasured and are stale as of 2026-09-05:

```
$ curl -s https://hex.pm/api/packages/burrito  → 1.6.0  2026-07-24
$ curl -s https://hex.pm/api/packages/ex_tauri → 0.2.0  2026-07-12
```

The Context cites Burrito 1.5.0 and an ex_tauri README stating OTP 27. Burrito's README states precompiled
ERTS "from OTP-25.3 onwards" for macOS, Linux and Windows rather than a cap at 28, and Elixir 1.20 requires
OTP 27+ and is compatible with OTP 29.

The decision to pin OTP 28 may still be correct. It is currently unjustified. Slice 001 measures which ERTS
versions Burrito 1.6.0 fetches per target and what ex_tauri 0.2.0 states, and this ADR is finalised on that
measurement rather than on the two facts above.
