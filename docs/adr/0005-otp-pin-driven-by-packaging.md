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

## Second correction, appended 2026-09-06

**Supersedes the correction above.** That correction said the OTP 28 pin "may still be correct" and was
"currently unjustified", and raised OTP 29 as a live possibility on the strength of Burrito's README saying
precompiled ERTS is available "from OTP-25.3 onwards". The pin is now measured rather than read, and the
README's phrasing does not survive contact with the artifact index.

**Method.** `burrito` 1.6.0 was fetched from hex and unpacked. `Burrito.Util.ERTSUniversalMachineFetcher` names
three artifact sources: the official OTP release page for Windows, and a third-party BEAM-machine CDN for macOS
universal and for Linux per architecture. Each was probed with `curl -I` per OTP version.

**Result, 2026-09-06.**

| OTP | macOS universal | linux x86_64 | linux aarch64 | Windows |
|---|---|---|---|---|
| 27.3.4.17 | 404 | 404 | — | 200 |
| 28.5.0.5 | **200** | **200** | **200** | **200** |
| 28.5.0.6 | 404 | 404 | 404 | 200 |
| 29.0.6 | 404 | 404 | 404 | 200 |

1. **The OTP 28 pin stands, by measurement.** The CDN carries only the OTP 28 line for macOS and Linux, so the
   packaging chain admits no other major version today.
2. **OTP 29 is unavailable**, returning 404 on macOS and on both Linux architectures. The previous correction's
   suspicion that OTP 29 had become viable is withdrawn.
3. **The exact pin is 28.5.0.5**, the newest 28.x present on all four targets. 28.5.0.6 is released and is on the
   Windows download page, but its macOS and Linux artifacts have not been built, so Burrito cannot fetch them.
4. **`ex_tauri` 0.2.0 declares `otp_release: "~> 27.0"`** and gives as its reason that "OTP 28 doesn't have
   universal macOS binaries available yet". **The probe refutes that reason on the target it names**: OTP 28
   macOS universal returns 200 and OTP 27 macOS universal returns 404. The constraint is a stale fact.

**Scope of point 4.** Whether `ex_tauri` 0.2.0 *actually runs* on the pinned OTP is slice 001's first measurement,
not this ADR's claim. If it refuses, that is slice 001's decision under ADR-0004's alternatives, and it is not a
reason to change this pin — the pin follows what the packaging chain can fetch for all four targets, and a
declared constraint resting on a refuted fact does not outrank a measurement.

**Standing risk.** Windows tracks OTP releases immediately while the other three targets depend on a third-party
CDN's build queue, so the newest packageable OTP is whatever that CDN last built, and it lags. Re-run the probe at
every phase boundary, per `VERSIONS.md`'s re-verification procedure.
