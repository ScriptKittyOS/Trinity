# Proof for slice 003: A FIPS build leg in CI, from source

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/003-fips-build-leg · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
A `fips` job in the gate workflow runs the whole gate on an OTP 28.5.0.5 built from source with `--enable-fips`
against the OpenSSL of a UBI9 container (Red Hat Enterprise Linux 9.8, `openssl-libs 3.5.8`, the 3.0.7 FIPS
provider), in FIPS mode, on every push. The image is built by its own workflow and pushed to the repository's
registry under a tag derived from the two files that define it. The mode is entered by OTP's own `fips_mode`
setting with the crypto application loaded first (`ERL_AFLAGS`), which was the measured condition. Ten findings
in NOTES.md; the two that reach past this slice are that Hex's client and OTP's TLS 1.3 client cannot reach
hex.pm and GitHub's release host from inside the mode (docs/fips-leg.md, findings 1 and 2), so the leg fetches
and compiles dependencies with the mode off and the gate's `hex.audit` step clears the flags.

## Gate
On the leg (run 35538136447, job 106150777683, `fips`, all steps success):
```
$ mix gate                                   (ERL_AFLAGS="-crypto fips_mode true -eval application:load(crypto)", TRINITY_FIPS_LEG=1)
1123 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 87 locked packages, none disagreeing with 50 pins
Result: 268 passed, 12 excluded
trinity.coverage: 023 75.39% vs 022 74.85%: OK
plan_check: PASS
```
On this machine (default leg's view, `crypto:info_fips()` = `not_supported`, under a 32 GiB cgroup, tree 39518c2):
```
$ mix gate
1123 mods/funs, found no issues.
Result: 265 passed, 15 excluded
trinity.coverage: 023 75.39% vs 022 74.85%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 1123 mods/funs, found no issues.

## Tests
```
$ mix test --cover                           (this machine, tree 39518c2)
Result: 265 passed, 15 excluded
|     75.39% | Total                                  |
```
On the leg (run 35538136447, step "The FIPS tests by name, and this leg's coverage"):
```
$ mix test --cover | grep -E 'Result:|\| *Total'
Result: 268 passed, 12 excluded
|     75.39% | Total                                  |
```
`coverage.tsv` row: `003  75.39  39518c2  2026-09-20` (unchanged from 023: the four new tests cover no `lib/`
line, and the leg reports the same total).

The slice's four tests, `mix test --trace test/fips` on the leg (run 35538136447):
```
Trinity.Fips.ModeTest [test/fips/mode_test.exs]
  * test the leg's declaration and the runtime's FIPS report agree (0.02ms) [L#16]
  * test on the FIPS leg AC2: eddsa is refused with notsup; ecdsa on secp384r1 with sha384 signs and verifies (13.5ms) [L#40]
  * test on the FIPS leg AC3: the committed listing is what this leg prints (386.7ms) [L#58]
  * test on the FIPS leg AC1: the mode is enabled and crypto:info/0 names the FIPS provider's build (0.04ms) [L#30]
Result: 4 passed
```
On this machine the same file: `Result: 1 passed, 3 excluded` (the untagged test asserts `not_supported` here).

## Acceptance criteria evidence

### AC1 [auto]: on the FIPS leg, `crypto:info_fips()` returns `enabled` and `crypto:info/0` carries `fips_provider_buildinfo` (log excerpt with the run id)
Run 35538136447, job 106150777683, step "The runtime is in FIPS mode", which runs
`erl -noshell -eval 'enabled = crypto:info_fips(), io:format("~p~n", [crypto:info()]), halt().'` (a badmatch exits
non-zero; the step is success):
```
#{otp_crypto_version => "5.8.3.2",compile_type => normal,link_type => dynamic,
  cryptolib_version_compiled => "OpenSSL 3.5.8 25 Aug 2026",
  cryptolib_version_linked => "OpenSSL 3.5.8 25 Aug 2026",
  fips_provider_available => true,
  fips_provider_buildinfo => "3.0.7-cda111b5812c30d4"}
```
And the test `on the FIPS leg AC1: ...` above, passed on the same run.

### AC2 [auto]: on the FIPS leg, `crypto:sign/4` with `eddsa` returns `notsup` and with `ecdsa` on `secp384r1` and `sha384` returns a signature that verifies (test)
`on the FIPS leg AC2: eddsa is refused with notsup; ecdsa on secp384r1 with sha384 signs and verifies`, passed on
run 35538136447. The test signs and verifies with a fresh P-384 key, refutes a verify over altered data, and
asserts `{:notsup, _, _}` raised as `ErlangError` for `crypto:sign/4` and `crypto:verify/5` with a fixed RFC 8032
Ed25519 key; measured on the image before the test was written, the value is
`{notsup, {"pkey.c", 235}, "Unsupported algorithm in FIPS mode"}`. Key generation for Ed25519 fails at a different
place (`{error, {"evp.c", 264}, "Can't make context"}`), so the test asserts only that it raises.

### AC3 [auto]: the committed `crypto:supports/1` diff between the two legs matches what the leg prints (test)
Two halves on the same image, so the diff isolates the mode alone. Mode on: the test `on the FIPS leg AC3: the
committed listing is what this leg prints` runs `elixir scripts/crypto_supports.exs` and asserts its output equals
`docs/fips-leg/supports-fips.txt` byte for byte; passed on run 35538136447. Mode off: the step
`crypto:supports/0 with the mode off matches docs/fips-leg/supports-default.txt` runs the same script under
`ERL_AFLAGS="-eval application:load(crypto)"` and `diff`s against the committed file; success on the same run.
`docs/fips-leg/supports.diff` is `diff` of the two committed files: 51 entries removed (`grep -c '^<'`), listed by
category in docs/fips-leg.md.

### AC4 [auto]: the whole gate runs on the leg; every red is either fixed or listed by test name with its owning slice in `docs/fips-leg.md`; there is no skip tag
The gate section above: `mix gate` exit 0 on the leg with 268 passed and 12 excluded, the same 12 the default
leg excludes by tag (`:live`, `:desktop`, `:eval`). No test in the tree went red for a removed algorithm, so the
list in docs/fips-leg.md is empty as a fact about this tree on this date, and says so. The reds the leg did
produce on the way were the leg's own (NOTES findings 2, 5 and 6) and are fixed. `git grep -n '@tag :skip\|@moduletag :skip' test/` prints nothing.

### AC5 [auto]: gate green on both legs; coverage line reported
Run 35538136447: `gate` success, `postgres` success, `fips-tag` success, `fips` success. Coverage: 75.39 % on the
default leg (`Result: 265 passed, 15 excluded`, `trinity.coverage: 023 75.39% vs 022 74.85%: OK`) and 75.39 % on
the FIPS leg (the Tests section above).

## Manual verification for the reviewer
None; SLICE.md tags every criterion `[auto]`. If the reviewer wants the leg on a machine, the last section of
docs/fips-leg.md is the two commands.

## Deviations from SLICE.md
Stated in NOTES.md before code: (a) a second job rather than a matrix entry, as `postgres` is, so the required
check keeps its name; (b) superseded by finding 1: the mode is entered by OTP's `fips_mode` setting through
`ERL_AFLAGS`, not by Red Hat's variable. Two more, found during the build and recorded in NOTES.md: (c) the
dependency fetch and compile run with the mode off, and the gate alias's `hex.audit` step clears `ERL_AFLAGS`
(findings 3 and 4; docs/fips-leg.md findings 1 and 2); (d) SLICE.md's "Out" paragraph calls UBI9's OpenSSL a
3.0 line and it is 3.5.8 as of 9.8, so ML-DSA is listed with the mode off (finding 9); SLICE.md is not edited.

## Versions touched
`VERSIONS.md` updated: yes, one toolchain row for the image's base (`ci/fips/Containerfile`, by digest); no
dependency changed. `mix hex.outdated` not run.

## Git
```
$ git log --oneline main..HEAD
39518c2 feat(s003): the leg prints the FIPS tests by name and its coverage line
f9c5eed fix(s000): plan_check's exists_prefix and the sign-off check read their whole input
ed2f74a fix(s003): the fips job marks the workspace safe for git
6ed96bf fix(s003): diffutils in the image
b74da2f fix(s003): the image's self-check matches enable_fips_mode/1's true
ad8bc17 feat(s003): the FIPS image, the leg in the gate, the mode tests and the supports record
7179cac docs(s003): G1 plan with the FIPS mechanism measured, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the header's "Final commit" placeholder: the closing commit is `567507d` (`feat(s003): complete slice
003 (FIPS build leg)`), and this correction rides on the commit after it, which also names the CI run of the
close in NOTES.md's minutes table.
