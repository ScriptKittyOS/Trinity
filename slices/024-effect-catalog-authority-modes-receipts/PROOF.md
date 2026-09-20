# Proof for slice 024: Effect catalog, authority selection, local receipts

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/024-effects-authority-receipts · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
The membrane: every tool call is decided once by the gate and receipted before anything runs; a read runs
directly with a query receipt, everything else becomes a staged effect that `Trinity.Effects.execute/2` admits
or denies with a receipt (decision, effect class and catalog, the fingerprint re-derived, the idempotency key,
the authority in force), and `Trinity.Authority.Local` is the one caller of `execute/2` for effectful tools.
Receipts are per-scope hash chains in their own database, signed through a seam (Ed25519 by default, P-384 in
FIPS mode as the `fips` leg proves, ML-DSA-87 by configuration where the runtime has it) over DSSE's PAE with the
scheme as payload type, with RFC 7638 key ids, an append-only registry the verifier reads the algorithm from,
RFC 5848-shaped checkpoints over query receipts, a verifier with the exit vocabulary and a standalone copy of it
that runs from an empty directory. `TRINITY_AUTHORITY` is read once at boot and refuses by name. Fourteen
findings in NOTES.md; the one that reaches past this slice is the Session dropping a decision made while its
tools still ran (`fix(s021)`, finding 5).

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree f977b84)
1411 mods/funs, found no issues.
... SCAN COMPLETE ...                        (sobelow --exit --skip: no finding)
No retired or security advisory packages found
No vulnerabilities found.
Result: 317 passed, 17 excluded
trinity.coverage: 003 75.39% vs 023 75.39%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 1411 mods/funs, found no issues.

CI, run 35542904049 on the tree at f977b84: `gate` success (317 passed, 17 excluded), `postgres` success
(309 passed, 25 excluded), `fips-tag` success, `fips` success (322 passed, 12 excluded: the `:fips` tests
included, coverage 76.43 %).

## Tests
```
$ mix test --cover                           (tree f977b84)
Result: 317 passed, 17 excluded
|     76.55% | Total                                  |
```
`coverage.tsv` row: `024  76.55  f977b84  2026-09-20` (from 75.39 at 023 and 003). The new modules:
Effects 90.70 %, Effects.Runner 96.97 %, Authority.Local 90.00 %, Authority.Selection 95.65 %, Verifier
89.87 %, KeyCustody 84.91 %, ChainWriter 81.82 %, KeyRegistry 79.17 %, Signer.P384 77.78 %, Signer.MLDSA87
20.00 % (no runtime here carries it; measured on the 003 image at G1), the two mix tasks 0 % (they run the
verifier and the export, which the tests cover directly).

The slice's 51 tests in its own files (`mix test --trace test/trinity/receipts test/trinity/effects
test/trinity/authority test/trinity_web/live/receipts_live_test.exs`):
```
* test the planted bypass is a real bypass: it runs the effectful tool, which is what the census exists to catch [L#51]
  * test the planted bypass is a real bypass: it runs the effectful tool, which is what the census exists to catch (5.9ms) [L#51]
  * test the callers of execute/2 on a tool module are the two allowed and the one planted (15.2ms) [L#20]
  * test Tools.Runner.call_tool/3 runs an effect: :none entry and refuses an effectful one by name (2.7ms) [L#41]
  * test the standalone assertion: this suite booted under local, no adapter module is loaded, and every TCP peer belongs to the database (7.6ms) [L#60]
  * test a present module implementing every callback is selected (0.7ms) [L#32]
  * test a present module missing a callback is refused naming the callback (0.6ms) [L#27]
  * test nil, the empty string and local all select Local (0.00ms) [L#15]

  * test boot!/0 reads the environment and raises with the named condition on refusal; the selection is unchanged (3.5ms) [L#36]
  * test an absent module is refused as not loaded, by name (0.09ms) [L#19]
  * test AC7: a stranger's run from an empty directory: verified is 0; the outcomes carry their codes (1590.1ms) [L#60]
  * test the script and the in-app verifier agree on every outcome (1607.4ms) [L#107]

  * test changing a policy module changes the hash; an unchanged one does not (14.4ms) [L#51]
  * test the boot receipt of this run: scope boot, signed, the authority, the signer and the policy hash (7.3ms) [L#15]
  * test the list covers the modules that decide (5.6ms) [L#38]
  * test the boot page shows this run's boot receipt with the authority, the signer and the policy hash, and verifies (96.0ms) [L#65]
  * test the chat links to its receipts (19.0ms) [L#60]
  * test a session's chain: the rows in order, signed or checkpointed, and verify runs to exit 0 (11.7ms) [L#29]
  * test an empty scope says so (2.0ms) [L#55]
  * test selection a configured ML-DSA-87 is refused where the runtime lacks it, naming the algorithm (0.1ms) [L#66]
  * test the seam the RFC 7638 thumbprint: lexicographic members, no whitespace, SHA-256, base64url (0.04ms) [L#51]
  * test custody boot generates the key once (0600), appends its registry row, and a second boot reuses it (0.4ms) [L#78]
  * test custody sign reads the key file at every call: removed mid-run, the next sign is unavailable (1.1ms) [L#99]
  * test the seam ML-DSA-87 reports itself unavailable or available from the runtime, never from the build (0.08ms) [L#47]
  * test the seam each implementation signs and verifies its own family over the PAE, and refuses altered bytes (4.2ms) [L#27]
  * test custody a key file whose id is not in the registry refuses to boot, naming the id (0.6ms) [L#124]
  * test selection outside FIPS mode the default is Ed25519; in FIPS mode (the fips leg) it is P-384 (0.05ms) [L#61]
  * test the seam the scheme strings resolve to their implementation and carry the family (0.07ms) [L#40]
  * test custody the registry is append-only: a status change is a new row and the newest wins (0.4ms) [L#108]
  * test AC8: the algorithm comes from the registry, not the body; a foreign family is refused at the scheme string (3.0ms) [L#143]
  * test AC3: a chain with a gap, a wrong prev_hash, or a forged signature is 1 (2.7ms) [L#122]
  * test AC3: 1,000 mixed receipts verify with their checkpoints; one byte in any signed_payload is 1 (180.0ms) [L#73]
  * test coverage: a query receipt no checkpoint covers is 1 unless the caller waives coverage (3.3ms) [L#271]
  * test AC3: an unknown key id is 5 (trust not established); a compromised key is 6 (1.9ms) [L#99]
  * test AC5: the signing key removed mid-run: the next effect is denied, the alarm sounds, no unsigned receipt row exists; a read is refused too, because its decision cannot be receipted (5.4ms) [L#168]
  * test the idempotency key: a second execution of the same session and call id is denied with a receipt (2.3ms) [L#126]
  * test Local: stage stamps, decide follows the gate, execute runs the tool or refuses a denial, receipt appends (0.5ms) [L#233]
  * test AC4: arguments mutated after the decision are denied at execution with a receipt (M2 re-verify) (1.2ms) [L#95]
  * test AC3: every gate decision and every effect yields a receipt: a read gives decision and query; an effect gives decision, admit and done (2.0ms) [L#41]
  * test a :catalog tool absent from the catalog, or a decision other than allow, is denied before anything runs (1.0ms) [L#140]
  * test a denied call yields a decision receipt and nothing else; an asked call the same (1.0ms) [L#78]
  * test AC9: query checkpoints a query row after the last checkpoint and before shutdown is covered by the shutdown checkpoint (0.7ms) [L#181]
  * test AC9: query checkpoints after N query receipts a checkpoint names the tail and its coverage; its signature verifies (1.0ms) [L#136]
  * test AC9: query checkpoints on rehydrate, uncovered query rows are checkpointed before a new row is accepted (12.5ms) [L#193]
  * test refusals on start a tail altered on disk stops the writer with the reason (4.0ms) [L#222]
  * test the scheme string resolves for every row and the implementations agree with the registry (0.1ms) [L#295]
  * test AC5 at the writer: the key removed mid-run, the next signed receipt is refused, the alarm sounds, no row is written (1.0ms) [L#97]
  * test rows chain: gapless seq, each prev_hash the previous receipt_hash, signed kinds verify, query rows unsigned (1.8ms) [L#43]
  * test the census: ChainWriter is the only inserter into receipts; the planted bypass is named (6.1ms) [L#262]
  * test AC9: query checkpoints T milliseconds after the first uncovered query row, a checkpoint is written by time (151.8ms) [L#169]
  * test concurrent appenders to one scope produce one chain: no two rows share a prev_hash (3.6ms) [L#81]
  * test refusals on start a checkpoint whose tail is not in the chain, or whose signature fails, stops the writer (1.2ms) [L#237]
Result: 51 passed
```
Plus `test/fips/receipts_test.exs` (2, on the leg), the mode-aware assertions in `test/trinity/tools/units_test.exs`,
`test/trinity/sessions/units_test.exs`, `test/trinity/repo_config_test.exs` and `test/trinity/tools/catalog_census_test.exs`.

## Acceptance criteria evidence

### AC1 [auto]: census test: exactly one caller of `execute/2` for effectful tools; a planted bypass is flagged (both outputs)
`the callers of execute/2 on a tool module are the two allowed and the one planted` (test/trinity/effects/census_test.exs):
the population is `git ls-files 'lib/*.ex' 'test/support/*.ex'` grepped for a call of `execute(` on a module
value (receivers `authority`, `impl`, `executor` and Erlang atoms excluded by name); the result is exactly
`lib/trinity/authority/local.ex`, `lib/trinity/tools/runner.ex` and the planted
`test/support/effects/bypass.ex`. The second caller is a caller for reads only: `Tools.Runner.call_tool/3 runs an
effect: :none entry and refuses an effectful one by name` asserts `{:error, {:effectful_tool_outside_membrane,
"write_note"}`. The third test proves the plant is a real bypass (it runs the effectful tool), which is what
the census exists to catch. With `test/support/effects/bypass.ex` absent the census fails on its own assertion,
so it cannot pass by not looking.

### AC2 [auto]: `TRINITY_AUTHORITY` set to a module that is absent, or present but not implementing the behaviour, refuses to start and names which condition failed; `local` starts; the standalone assertion passes
test/trinity/authority/selection_test.exs: `an absent module is refused as not loaded, by name`
(`{:error, {:not_loaded, "Trinity.NoSuchAuthority"}`, no atom made from the text); `a present module missing a
callback is refused naming the callback` (`{:missing_callback, Trinity.TestAuthority.Partial, {:execute, 3}`);
`boot!/0 reads the environment and raises with the named condition on refusal; the selection is unchanged`
(the message `TRINITY_AUTHORITY refused: module Trinity.TestAuthority.Partial does not implement execute/3`,
and the child spec's start exits with it); `nil, the empty string and local all select Local`; `the standalone
assertion: this suite booted under local, no adapter module is loaded, and every TCP peer belongs to the
database` (no loaded module implements the behaviour but `Local` and the test adapters; every TCP peer owned by
a `:trinity` process is a `DBConnection.Connection`; NOTES finding 13 for what the runners' Hex client is).

### AC3 [auto]: every gate decision and every effect yields a receipt; chain verifies across 1,000 mixed receipts; tampering one byte in any `signed_payload` → verifier exit 1; unknown key id → 5; registry status `compromised` → 6
test/trinity/effects/membrane_test.exs `AC3: every gate decision and every effect yields a receipt: a read gives
decision and query; an effect gives decision, admit and done` and `a denied call yields a decision receipt and
nothing else; an asked call the same`. test/trinity/receipts/verifier_test.exs `AC3: 1,000 mixed receipts verify
with their checkpoints; one byte in any signed_payload is 1` (bytes flipped at seq 1, 7, 500 and 1,000, each
`{:error, 1, {:hash_mismatch, seq}` or a body mismatch, `exit_code/1` 1); `AC3: an unknown key id is 5 (trust
not established); a compromised key is 6`; `AC3: a chain with a gap, a wrong prev_hash, or a forged signature is 1`.
`mix trinity.receipts.verify --scope <s>` and `--file <f>` exit with the same codes.

### AC4 [auto]: fingerprint mismatch at execution (args mutated after approval) → denied + receipt (M2 re-verify)
`AC4: arguments mutated after the decision are denied at execution with a receipt (M2 re-verify)`: a staged effect
carrying the decision's fingerprint over one set of arguments and different arguments is denied
`{:fingerprint_mismatch, bound, derived}` with a `denied` effect receipt whose reason names it; the same staged
effect with the arguments the decision bound runs.

### AC5 [auto]: signing key removed mid-run → next effect denied, alarm event emitted, no unsigned receipt row exists
`AC5: the signing key removed mid-run: the next effect is denied, the alarm sounds, no unsigned receipt row exists;
a read is refused too, because its decision cannot be receipted` (membrane_test.exs): after one effect, the key
file is removed; the next effect's decision cannot be receipted (`{:decision_not_receipted, {:signer_unavailable,
:signer_unavailable}`), the telemetry event `[:trinity, :receipts, :signer_unavailable]` arrives and
`:alarm_handler` holds `:trinity_receipts_signer`; the row count is unchanged and every non-query row has a
signature; a staged effect reaching the membrane directly is denied at admission and the denial's own receipt
failure is named; the key restored, the next effect runs. At the writer: `AC5 at the writer: the key removed
mid-run, the next signed receipt is refused, the alarm sounds, no row is written` (chain_writer_test.exs).

### AC6 [auto]: boot receipt carries `core_policy_hash`; changing a policy module changes the hash (test)
test/trinity/effects/boot_receipt_test.exs: `the boot receipt of this run: scope boot, signed, the authority,
the signer and the policy hash` (`meta["core_policy_hash"] == CorePolicy.hash()`, unsigned per the R21 default,
the boot chain verifies); `changing a policy module changes the hash; an unchanged one does not` (a module
created, hashed twice, recompiled with another body, hashed again: equal, then different); `the list covers the
modules that decide`. NOTES finding 10 for why the hash is over stripped beams.

### AC7 [auto]: `bin/verify_receipt.exs` runs from an empty directory against an exported receipt file + registry (stranger test)
`AC7: a stranger's run from an empty directory: verified is 0; the outcomes carry their codes`
(test/trinity/receipts/standalone_verifier_test.exs): the script and the export copied into a directory holding
nothing else (asserted by `File.ls!`), run with `elixir` as a separate OS process: `verified: 12 receipts, 1
checkpoints` exit 0; a tampered row `invalid: ...` exit 1; an empty registry `trust not established: ...` exit 5;
a compromised row exit 6; a disallowed scheme exit 1; no argument exit 2. `the script and the in-app verifier
agree on every outcome` over six variants.

### AC8 [auto]: algorithm agility
Registry over body, and the scheme string before any signature, on both legs:
`AC8: the algorithm comes from the registry, not the body; a foreign family is refused at the scheme string`
(verifier_test.exs): a receipt whose scheme names the foreign family under a key whose registry row names the
chain's is `{:scheme_family_mismatch, ...}` before any signature check, both with the column alone and with the
body and hash rewritten to agree (mutant 1: a verifier reading the algorithm from the receipt would report a
signature failure instead, a different reason); a receipt of the foreign family with its own registry row is
`{:scheme_not_allowed, ...}` when the verifier is told to accept only the chain's family, and verifies on its own
where the foreign signer can sign (mutant 2). The FIPS half, run 35542904049 job 106163682937 on the `fips`
leg: `the mode is on, Ed25519 reports unavailable, P-384 is selected and the boot receipt names it` and `no effect
is denied for want of a signer: an effect runs, its receipts are P-384 and verify` (test/fips/receipts_test.exs),
`Result: 6 passed` for `mix test --trace test/fips`, and the whole suite there `322 passed, 12 excluded`.

### AC9 [auto]: query-receipt checkpoints
test/trinity/receipts/chain_writer_test.exs: `after N query receipts a checkpoint names the tail and its
coverage; its signature verifies` (N = 3 in the test's window); `T milliseconds after the first uncovered query
row, a checkpoint is written by time`; `a query row after the last checkpoint and before shutdown is covered by the
shutdown checkpoint`; `on rehydrate, uncovered query rows are checkpointed before a new row is accepted` (a
killed writer, the next start's continue writes the `rehydrate` checkpoint before the append it then serves).
The AC5 mutant (the denial on signer error removed) goes red in `AC5 at the writer` and in the membrane's AC5.

## Manual verification for the reviewer
None; SLICE.md tags every criterion `[auto]`.

## Deviations from SLICE.md
G1 (a) to (d) and, found during the build, (e) to (h): NOTES.md, "Deviations found during the build". The
research amendments A to E (NOTES.md, "Research") are additions within the slice's design, not deviations.

## Versions touched
`VERSIONS.md` updated: no dependency changed; `:sasl` added to `extra_applications` (OTP's own). `mix
hex.outdated` not run.

## Git
```
$ git log --oneline main..HEAD
f977b84 test(s024): the outbound-connection assertion is scoped to this application's processes
d6a2054 test(s024): the receipts tests derive the chain's family and the foreign one from the selection; the peer assertion describes the owner
120ff73 test(s024): mode-aware expectations for the fips leg; the peer assertion names the owner
a0ef284 refactor(s024): credo's seven findings and sobelow's nine
c583ef3 docs(s024): 01, 05, 07 and ADR-0013 as built
7170545 feat(s024): the FIPS half of AC8 for the leg; the policy hash over stripped beams; mode-aware assertions
3d6fc93 feat(s024): the receipts pages: a session's chain and the boot receipt, with verify
a44d820 feat(s024): CorePolicy covers the modules that decide; the boot receipt's tests (AC6)
e1461d2 test(s024): the membrane: the execute/2 census with a planted bypass, every decision and effect receipted, the M2 re-verify, the idempotency key, the catalog and decision checks, the key removed mid-run, Local's callbacks
69cb4e4 feat(s024): the membrane, its runner as the seam in force, the executor on Tools.Runner
85c0cdb fix(s021): a decision that arrives while the tools still run is postponed, not dropped
4b356af test(s024): the authority selection: named refusals, the child spec's start failure, the standalone assertion under local
689542a feat(s024): the verifier's tests, the export and verify tasks, the standalone script
6dd6a86 feat(s024): the chain writer, checkpoints, the authority behaviour and Local, the boot receipt, the verifier
b34cd8f feat(s024): the receipts repo and file, the signer seam, key custody and the registry
9f646ca docs(s024): the design checked against DSSE, RFC 8725, RFC 7638, RFC 5848, C2SP and FIPS 186-5; five G1 amendments
95b3660 docs(s024): G1 plan with the signing and insert costs measured, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the header's "Final commit" placeholder: the closing commit is `2ab8d28` (`feat(s024): complete
slice 024 (effect catalog, authority selection, local receipts)`), and this correction rides on the commit after it.
