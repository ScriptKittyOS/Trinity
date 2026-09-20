# Slice 003: A FIPS build leg in CI, from source, so FIPS claims are proven rather than asserted

| Field | Value |
|---|---|
| Phase | 0 Foundation |
| Milestone | M2 Acts |
| Size | M |
| Depends on | 000 |
| Status | see ROADMAP.md |

Added 2026-09-20. Counted toward M2 Acts because its reason to exist is slice 024's FIPS property tests, which
cannot run anywhere else: the developer machine's OTP reports `crypto:info_fips()` as `not_supported`, and the
hosted BEAM images the gate uses are not FIPS builds.

## Goal
A second entry in the gate workflow's matrix that runs the whole suite on an OTP 28.5.0.5 built from source with
`--enable-fips` against the validated OpenSSL of a UBI9 container, with FIPS mode entered before the crypto
application loads, and a smoke that proves the mode is on. The default leg stays exactly as it is.

## Why
Slice 024's amendment says FIPS mode selects P-384 and never denies for want of a signer. Until a build runs
in FIPS mode, that is a sentence. This leg is the measurement. It also answers, once, what else in the tree
reaches an algorithm FIPS mode removes.

## Scope
**In:**
- A container image built by its own workflow, rebuilt when `.tool-versions` changes: UBI9, the distribution's
  OpenSSL and its FIPS provider, OTP 28.5.0.5 from source with `--enable-fips`, Elixir 1.20.4. Published to the
  repository's container registry so the gate leg pulls rather than builds.
- The gate leg: `fips_mode: true` for `:crypto` in the release's `sys.config` equivalent for tests, set before
  crypto loads; the smoke `crypto:info_fips() =:= enabled` and the `fips_provider_buildinfo` key present in
  `crypto:info/0`; then `mix test` and the rest of the gate as the default leg runs it.
- A committed record of `crypto:supports/1` on the FIPS leg diffed against the default leg, so the removed
  algorithms are a list in the tree and not a memory.
- Runner minutes measured over the first ten runs and written into NOTES.md.
**Out:**
- Making FIPS mode the default anywhere; changing the OTP pin; ML-DSA (the UBI9 OpenSSL is a 3.0 line and does
  not carry it; that measurement waits for a build against OpenSSL 3.5 or later and is `:unknown` until then).
- A FIPS-mode desktop bundle. Whether Burrito can wrap a `--enable-fips` ERTS is slice 100's question.

## Design notes
Entering or leaving FIPS mode on a running node is unsupported by OTP, so the leg sets the mode in configuration
and never toggles it in a test. A test that needs a removed algorithm on this leg is a finding, not a skip: it is
listed in the committed diff with the slice that owns it.

## Deliverables
- `.github/workflows/fips-image.yml` and the Containerfile; the second matrix entry in `.github/workflows/gate.yml`;
  `docs/fips-leg.md` with the `crypto:supports/1` diff and how to reproduce the image; NOTES.md with the minutes.

## Acceptance criteria
1. [auto] On the FIPS leg, `crypto:info_fips()` returns `enabled` and `crypto:info/0` carries
   `fips_provider_buildinfo` (log excerpt with the run id).
2. [auto] On the FIPS leg, `crypto:sign/4` with `eddsa` returns `notsup` and with `ecdsa` on `secp384r1` and
   `sha384` returns a signature that verifies (test).
3. [auto] The committed `crypto:supports/1` diff between the two legs matches what the leg prints (test).
4. [auto] The whole gate runs on the leg; every red is either fixed or listed by test name with its owning slice
   in `docs/fips-leg.md`; there is no skip tag.
5. [auto] Gate green on both legs; coverage line reported.

## Proof required
- For each criterion: the command and its output, or a test name and its result, with the run id. A sentence is
  not proof.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–5 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s003): complete slice 003 (FIPS build leg)` · tag `slice/003`

## Risks / open questions
- Building OTP from source is slow; the image workflow exists so the gate leg does not pay for it on every push.
  If the image cannot be cached in the registry for a reason found at G1, the leg runs on a schedule and on
  demand rather than on every push, and the slice says so.
- The validated provider a container ships is the distribution's claim; the slice cites the certificate number
  the distribution publishes and does not restate it as Trinity's.
