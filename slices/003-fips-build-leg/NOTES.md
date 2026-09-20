# Slice 003: NOTES

## Facts measured 2026-09-20 before any code

**The container can enter FIPS mode on a host that is not in FIPS mode.** `docker run --rm
registry.access.redhat.com/ubi9/ubi:latest` on this machine (Red Hat Enterprise Linux release 9.8, `openssl-libs
3.5.8-1.el9_8`, no `/proc/sys/crypto/fips_enabled`): `openssl list -providers` names only `default`; with
`OPENSSL_FORCE_FIPS_MODE=1` it names `base`, `default` and `fips` ("Red Hat Enterprise Linux 9 - OpenSSL FIPS
Provider", version `3.0.7-cda111b5812c30d4`, from `/usr/lib64/ossl-modules/fips.so`); under it `openssl genpkey
-algorithm ed25519` fails with `unsupported ... Algorithm (ED25519 : 111)` and a P-384 key generates. That
environment variable is Red Hat's own patch, so it is the leg's mechanism and is named as such in `docs/fips-leg.md`.
GitHub's hosted runners are not FIPS hosts, so the leg depends on it.

**UBI9 is no longer a 3.0 line.** SLICE.md's "Out" paragraph says the UBI9 OpenSSL is a 3.0 line and carries no
ML-DSA. As of 9.8 the library is 3.5.8 and only the FIPS provider is the 3.0.7 module. ML-DSA-87 through the
default provider on this image is therefore measurable in non-FIPS mode; that measurement belongs to slice 024
(amendment 6) and is written there when 024 opens, not here. SLICE.md is not edited; this note supersedes the
sentence for the reader.

**The registry.** `gh api /orgs/ScriptKittyOS/packages` answers 403 for this token (no `read:packages` scope), so
whether the image can be pushed to `ghcr.io/scriptkittyos/trinity-fips` is learned by the image workflow's first
run, under the job's own `packages: write` permission; the fallback SLICE.md names (schedule and on demand, the
image built in the leg itself) is line 6 below.

## G1 plan, 2026-09-20

Tree at `1b73b70` on `main` (023 approved); branch `slice/003-fips-build-leg`; ROADMAP row 003 to `in_progress` in
this commit. Each line names its test or its evidence.

1. `ci/fips/Containerfile`: `registry.access.redhat.com/ubi9/ubi:9.8` pinned by digest; `dnf install` of the build
   toolchain, `openssl-devel`, `ncurses-devel`; OTP 28.5.0.5 from the source tarball with `--enable-fips`; Elixir
   1.20.4 from the precompiled `elixir-otp-28.zip`; the versions read from `.tool-versions` as build args so the
   file is the one source. Evidence: `erl -noshell -eval 'io:format("~p~n",[crypto:info()])'` in the build log
   prints `fips_provider_available => true`.
2. `.github/workflows/fips-image.yml`: builds and pushes `ghcr.io/scriptkittyos/trinity-fips:<sha256 of
   .tool-versions and the Containerfile>` on push when either file changes, and on `workflow_dispatch`;
   `permissions: packages: write`. Evidence: a green run id and the image digest in PROOF.md.
3. `.github/workflows/gate.yml`: a second job `fips` (not a matrix entry, so `gate` keeps its context name, as
   `postgres` did) on `container: ghcr.io/scriptkittyos/trinity-fips:<tag>` with `OPENSSL_FORCE_FIPS_MODE=1`
   and `ERL_FLAGS="-crypto fips_mode true"`; the same steps as `gate`. Evidence: the run id; AC5.
4. `test/fips/mode_test.exs`, tagged `:fips`, excluded by tag on the default legs and included on this one:
   `crypto:info_fips() == :enabled`, `fips_provider_buildinfo` present in `crypto:info/0` (AC1); `crypto:sign/4`
   with `eddsa` raises `notsup`, `ecdsa`/`secp384r1`/`sha384` signs and verifies (AC2). Red first on this machine
   by construction (`not_supported` here), which is why the tag exists and the default legs exclude rather than
   skip it.
5. `docs/fips-leg.md` and `docs/fips-leg-supports.diff`: `crypto:supports/1` printed by `scripts/crypto_supports.exs`
   on both legs and the diff committed; `test/fips/supports_diff_test.exs` regenerates the leg's half and asserts
   it equals the committed file (AC3). The FIPS provider's version string and Red Hat's certificate reference are
   cited from Red Hat's page with the URL and the date read; nothing restated as Trinity's claim.
6. Every red on the leg is fixed in this slice when the fault is the test's, or listed by test name with its
   owning slice in `docs/fips-leg.md` when the fault is a removed algorithm (AC4); no skip tag is added. The
   registry fallback: if the push in line 2 is refused, the leg builds the image itself on a schedule and on
   `workflow_dispatch`, and SLICE.md's risk paragraph is what PROOF.md points at.
7. Minutes of the first ten leg runs, from `gh run list`, into this file (SLICE.md deliverable).
8. `docs/packaging.md` gains one paragraph pointing at `docs/fips-leg.md`; VERSIONS.md gains the image and its
   digest; the coverage line from the leg is reported beside the default leg's in PROOF.md (AC5).

Manual verification queue: none. Every criterion is `[auto]`, as SLICE.md states.

Deviations stated before any code: (a) the leg is a second job rather than a matrix entry, for the required-check
name, as SLICE.md's own precedent (`postgres`) did; (b) FIPS mode is entered by Red Hat's environment variable
rather than by the host, because the runner cannot be a FIPS host; both halves (the provider list and the
`notsup`) are asserted by the tests in line 4 so the mechanism is measured on every run.

## Findings, 2026-09-20, in the order they were met

1. **`ERL_FLAGS` does not enter the mode; `ERL_AFLAGS` with the application loaded first does.** OTP's
   `crypto:on_load/0` reads `fips_mode` only when `application:get_env(crypto, fips_mode)` is defined, which it is
   not before `application:load(crypto)`; the NIF loads on the first `:crypto` call, which under `elixir` comes
   before Mix loads the applications. Measured on the image with `elixir -e`: `ERL_FLAGS="-crypto fips_mode true"`
   leaves `crypto:info_fips()` at `not_enabled` and prints OTP's warning; `ERL_AFLAGS="-crypto fips_mode true
   -eval application:load(crypto)"` gives `enabled`. Red Hat's `OPENSSL_FORCE_FIPS_MODE=1` alone gives
   `not_enabled` in OTP's report, and is not needed once OTP loads the provider itself. **Supersedes G1
   deviation (b)**: the mechanism is OTP's own configuration, not the distribution's variable.
2. **The image's self-check matched the wrong atom.** `crypto:enable_fips_mode(true)` returns `true`, not `ok`;
   the first local build and the first `fips-image` run (35536968071) failed at the check after a complete
   build. `fix(s003)` at `b74da2f`.
3. **Hex cannot reach hex.pm in the mode** (docs/fips-leg.md finding 1): Hex 2.5.1 hardcodes TLS 1.0 and 1.1
   beside 1.2. `HEX_OFFLINE=1` was tried and does not serve `hex.audit`: neither `deps.get` on a complete lock nor
   an online `hex.audit` leaves registry entries an offline audit can read (measured, runs 3 and 4 in the
   container). The gate alias's `hex.audit` step now runs with `ERL_AFLAGS` cleared; a default leg does not set
   it, so nothing changes there.
4. **OTP's TLS 1.3 client fails a HelloRetryRequest, and the mode makes that common** (docs/fips-leg.md finding
   2, erlang/otp #8470): `rustler_precompiled` could not download mdex's NIF at compile time. The leg compiles
   dependencies with the mode off. Both workarounds were measured in the mode against
   `release-assets.githubusercontent.com` and `repo.hex.pm`: `middlebox_comp_mode: false`, or
   `supported_groups: [:secp256r1, :secp384r1, :secp521r1]`. **Follow-up for slice 002 (the TLS floor)**:
   Trinity's own clients in a FIPS deployment need one of these, or they fail against every server that retries.
5. **UBI's base has no `diff`** (run 35537134655). `diffutils` added to the image.
6. **`git ls-files` in the container read an empty tree** (run 35537462271): the checkout action's safe.directory
   entry lives under a HOME it removes afterwards. One `git config --global --add safe.directory` step before
   anything reads the tree.
7. **`plan_check.sh` flaked on a clean tree**: `printf | grep -q` under `set -o pipefail`, 1 spurious FAIL in 30
   runs (the ADR-0005 citation in slice 001's file), 0 in 60 after reading the whole input. Fixed as
   `fix(s000)` at `f9c5eed`; found because a local run failed and the next three passed. The push that carried
   the safe.directory fix went out on a `plan_check | tail -1` pipeline whose exit was `tail`'s, the mistake the
   gate alias's comment describes; recorded here so it is not repeated.
8. **Red Hat's page and the image disagree on the provider's build hash** (docs/fips-leg.md, the provider
   section): the page lists `3.0.7-395c1a240fbfffd8` under certificate #4857 for 9.8; the image reports
   `3.0.7-cda111b5812c30d4` from `openssl-fips-provider-so-3.0.7-11.el9_8`. Stated, not resolved; owner: the
   deployment's assessor.
9. **This OTP lists ML-DSA and SLH-DSA with the mode off** (`docs/fips-leg/supports-default.txt`: `mldsa44`,
   `mldsa65`, `mldsa87`, twelve `slh_dsa_*`), because UBI 9.8 links OpenSSL 3.5.8. Slice 024's amendment 6 can be
   measured on this image in non-FIPS mode; recorded here for 024's G1.
10. **No test in the tree reaches a removed algorithm.** The gate in the mode: 268 passed, 12 excluded, exit 0
    (in the image on this machine, run 5, 33.5 s wall; on the leg, run 35538136447). AC4's list of reds by test
    name is therefore empty as a fact about the tree on this date, not as a property of the leg.

## Runner minutes

Durations of the `image` and `fips` jobs on this branch, from `gh run view <id> --json jobs` (latest attempt of
each run; reruns replace the earlier attempt's times), derived 2026-09-20 after run 35538136447. Fewer than the
ten runs SLICE.md asks for exist at this line; the closing correction in PROOF.md extends the table with the
runs the close itself produces, and the ten-run figure is filled by the first `fix` or the next slice that
touches the leg, whichever is first.

| run | job | result | duration |
|---|---|---|---|
| 35536968071 | image | failure (finding 2) | 2m51s |
| 35537134611 | image | success | 2m55s |
| 35537462269 | image | success | 3m03s |
| 35536967968 | fips | failure (image not yet published) | 0m10s |
| 35537134655 | fips | failure (finding 5), rerun | 1m58s |
| 35537462271 | fips | failure (finding 6), rerun | 1m54s |
| 35537793241 | fips | success | 3m19s |
| 35538008648 | fips | success | 1m28s |
| 35538136447 | fips | success | 2m03s |

The image build is under three minutes on the hosted runner (OTP from source with the unused applications left
out), so the schedule-and-on-demand fallback SLICE.md names was not needed; the push to the registry under the
job's `packages: write` succeeded on the first complete build (finding 2 was the check, not the push). On a push
that changes the Containerfile, the `fips` job of the same push starts before the image lands and fails at the
pull; a rerun of the failed job after `fips-image` finishes is the procedure, and it happened twice here.

## Follow-ups
- Slice 002 (the TLS floor): set `supported_groups` or `middlebox_comp_mode` for Trinity's clients (finding 4).
- Slice 024: amendment 6 (ML-DSA-87) is measurable on this image with the mode off (finding 9); P-384 signatures
  from OTP are DER, 103 to 104 bytes, not the 96 the slice table names.
- Upstream: Hex's TLS version list (finding 3); OTP's HelloRetryRequest handling (#8470, finding 4).
- The ten-run minutes table (above).
