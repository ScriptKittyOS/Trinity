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
