# Slice 024: NOTES

## Measurements before any code

All on 2026-09-20. Signing through `:crypto.sign/4` over a 512-byte payload, 2,000 iterations after a warm-up,
`:timer.tc`, no Benchee (a dependency added mid-slice needs VERSIONS.md approval, and the measurement does not
need one).

| algorithm | where | signature bytes | sign µs | verify µs | signs per second |
|---|---|---|---|---|---|
| Ed25519 | this machine, OpenSSL 3.0.13 | 64 | 45.9 | 54.7 | 21,785 |
| ECDSA P-384 SHA-384 | this machine, OpenSSL 3.0.13 | 104 (DER) | 453.6 | 383.8 | 2,204 |
| Ed25519 | the 003 image, OpenSSL 3.5.8, mode off | 64 | 50.7 | 51.3 | 19,713 |
| ECDSA P-384 SHA-384 | the 003 image, mode off | 102 (DER) | 125.6 | 281.5 | 7,961 |
| ML-DSA-87 | the 003 image, mode off | 4,627 | 905.4 | 171.8 | 1,105 |
| ML-DSA-87 | this machine | unavailable (OpenSSL 3.0.13) | | | |
| ML-DSA-87 | the 003 image, mode on | refused: `{error, {"evp.c", 264}, "Can't make context"}` | | | |

Two corrections to SLICE.md's table, recorded rather than edited: OTP returns ECDSA signatures DER-encoded, 102
to 104 bytes, not the 96 raw bytes the table names; and ML-DSA-87 is reachable on the 003 image with the mode
off (UBI 9.8 links OpenSSL 3.5.8), so amendment 6's "compile-conditional, OpenSSL 3.5 or later" is testable on the
`fips` leg's image outside the mode, and refused inside it. OTP's calls: `generate_key(:mldsa87, [])`,
`sign(:mldsa87, :none, msg, priv)`, `verify(:mldsa87, :none, msg, sig, pub)`.

Insert cost, exqlite 0.x through `Exqlite.Sqlite3` on ext4, a receipt-shaped row (400-byte payload, 64-byte
signature, two 32-byte hashes), 3,000 rows, WAL:

| synchronous | rows per transaction | µs per row | rows per second |
|---|---|---|---|
| NORMAL | 1 | 20.4 | 48,974 |
| NORMAL | 100 | 6.1 | 164,835 |
| FULL | 1 | 273.7 | 3,654 |
| FULL | 100 | 12.4 | 80,530 |
| FULL | 1000 | 7.9 | 126,802 |

So the receipts file runs `synchronous: :full`, one row per transaction, at a cost of 274 µs per signed receipt,
which is far under any effect rate this tree produces. For query receipts (amendment 5): a checkpoint every
**N = 100** rows or **T = 5 s**, whichever first, and on shutdown. At N = 100, P-384's per-row share of the
signature is under 5 µs on either machine, below the row's own insert cost, which is the number the amendment
asked for; at the measured rates per-row signing would also have been affordable, and the amendment stands as
the owner accepted it (plan decision 6).

Slice 003 measured on the leg that `eddsa` sign and verify raise `notsup` in the mode and P-384 signs; that is
AC8's premise, proven there.

## Legal review (R21): the signed field set, as proposed

SLICE.md says the `signed_payload` field set goes to the owner before the slice starts, and names a default
until cleared. This slice builds the default and nothing more; clearing it or changing it is an owner decision
that lands as a scheme bump, never as an edit to rows already written.

Signed bytes (RFC 8785 canonical JSON of this map, in this key order after canonicalisation):
`scheme` (`receipt_v2_ed25519` | `receipt_v2_p384` | `receipt_v2_mldsa87`), `seq`, `chain_scope`, `prev_hash`
(hex, or null for the first row of a scope), `kind`, `subject` (a map of references: `session_id`, `call_id`,
`tool`, `approval_id`, `effect`, as the kind needs), `decision` (for decision and effect receipts: the outcome
and its basis, e.g. `allow` by `once`), `fingerprint` (the call's, hex, or null), `at` (RFC 3339 UTC), `key_id`.

Unsigned metadata (its own column, `meta`): `core_policy_hash`, `canonicalization_version`, `authority` (the
module in force), the tool definition digest. `receipt_hash` is SHA-256 over the signed bytes; `signature` is
the signer's over the signed bytes themselves, so a verifier holding the bytes and the registry needs nothing
else, and `receipt_hash` is derived (the next row's `prev_hash`).

## G1 plan, 2026-09-20

Tree at `e8733c7` on `main` (003 approved); branch `slice/024-effects-authority-receipts`; ROADMAP row 024 to
`in_progress` in this commit. Each line names its test.

1. `Trinity.Repo.Receipts` started (its own SQLite file `receipts.db` beside the primary, `synchronous: :full`,
   pool 1; on Postgres the same database with `migration_source: "receipts_migrations"`), migration for
   `receipts` (docs/05 columns, `signed_payload` as the canonical text, plus `meta`) and `receipt_checkpoints`
   (`chain_scope`, `seq`, `receipt_hash`, `signature`, `key_id`, `at`). Test: pragmas read back; unique
   `(chain_scope, seq)`.
2. `Trinity.Receipts.Signer` behaviour (`algorithm/0`, `sign/2`, `verify/3`) with `Ed25519`, `P384` and, when
   `:mldsa87 in :crypto.supports(:public_keys)`, `MLDSA87`; `Trinity.Receipts.KeyCustody`: selects P-384 when
   `:crypto.info_fips() == :enabled`, Ed25519 otherwise, generates the key on first run into
   `<data_dir>/keys/receipts.key` (0600) and appends the registry row to `<data_dir>/keys/registry.json`; reads
   the key file on every sign, never caches it (AC5's premise). Tests: selection by a mocked `info_fips`;
   registry append-only; a key file removed → `{:error, :signer_unavailable}`.
3. `Trinity.Receipts.ChainWriter` (ADR-0013): one per `chain_scope` under `Trinity.Receipts.Supervisor`, `:unique`
   in `Trinity.Registry`; `append/2` is a call; rehydrates the tail on start; signs per row for decision, effect,
   boot and cap kinds; chains query rows unsigned and checkpoints them at N/T/shutdown, re-signing the tail on
   rehydrate before a new row. A census test: `ChainWriter` is the only module inserting into `receipts` (a
   planted second insert path in test support must be named). Tests: 1,000 mixed receipts verify; a fork is
   impossible (two concurrent appenders, no two rows share a `prev_hash`); AC9's three checkpoint cases.
4. `Trinity.Receipts.Verifier` (pure: walks a scope by seq, recomputes hashes, resolves the algorithm from the
   registry row and never from the body, refuses a foreign scheme string before any signature check) with exit
   vocabulary `0 / 1 / 2 / 5 / 6`; `mix trinity.receipts.verify` and `mix trinity.receipts.export`;
   `bin/verify_receipt.exs` standalone on `elixir` alone (Elixir's own `JSON`, `:crypto`), run from an empty
   directory in a test (AC7). Mutants as tests: drop the registry lookup, drop the scheme check (AC8).
5. `Trinity.Authority` behaviour (`stage/2`, `decide/3`, `execute/3`, `receipt/2`), `Trinity.Authority.Local`,
   selection at boot from `TRINITY_AUTHORITY` in `Trinity.Authority.Selection` (refuses to start naming the
   failed condition: not loaded, or missing callback by name); the standalone assertion under `local`: no adapter
   module loaded, no outbound socket (AC2). `Local.execute/3` is the one caller of `execute/2` for effectful tools.
6. `Trinity.Effects` (the membrane, a module): `execute/1` over a `%Staged{}` (entry, args, ctx, decision,
   fingerprint, call id); revalidates the decision, re-derives the fingerprint from the args it holds (AC4),
   refuses a repeated `(session, call_id)` by asking the chain for an effect receipt with that subject (the
   idempotency key, no new state), checks the tool's effect is in `Effects.Catalog` for `:catalog`, checks the
   authority in force, and denies with a receipt on any mismatch; signing unavailable denies, sets
   `:alarm_handler` alarm `{:trinity_receipts_signer, reason}` and emits `[:trinity, :receipts, :signer_unavailable]`
   (AC5). `Trinity.Effects.Runner` becomes the `:tool_runner` implementation: `Tools.Runner` keeps lookup,
   validation, timeouts and concurrency and takes the executor as a function, so Tools never depends on Effects;
   the executor decides, writes the decision receipt, and for `:none` calls the tool directly with a query
   receipt, otherwise goes through the membrane. Census (AC1): the population is `git ls-files 'lib/**/*.ex'
   'test/support/**/*.ex'` grepped for `.execute(`; the allowed set is `Authority.Local` and the `:none` path in
   `Effects.Runner`; a planted bypass in test support is named.
7. `Trinity.CorePolicy` extended with the gate, catalog, membrane and authority modules; the boot receipt
   (scope `boot`, written by `Trinity.Receipts.Boot` after the supervisor starts) carries the selected authority,
   algorithm and key id in the signed bytes and `core_policy_hash` in `meta`; test: changing a policy module's
   object code changes the hash (AC6).
8. UI: `/sessions/:id/receipts` (the scope's rows, verify status) and `/receipts/boot` (the boot receipt; there is
   no Settings page in this tree yet, so it gets its own route and a nav link beside `/permissions`); LiveView
   tests.
9. Docs: 01 (the boundaries and the effect path as built), 05 (the two tables), 07 (the receipt section as built);
   ADR-0013 consequence line for the checkpoints table.
10. AC8's FIPS half runs on the `fips` leg: the boot receipt names P-384 there, no effect is denied for want of a
    signer; `test/fips/receipts_test.exs` tagged `:fips`.

Manual verification queue: none; every criterion is `[auto]`.

Deviations stated before any code: (a) the registry and key live in the data directory, not `priv/keys/`: `priv`
is the packaged tree, read-only under a release, and a key made on the user's machine is not the tree's to
carry; (b) query checkpoints are rows in `receipt_checkpoints` rather than a signature written onto the tail
row, because `receipts` is append-only and never updated (docs/05); "the tail carries a signature" is read as
"a checkpoint row names the tail"; (c) the boot receipt's page is `/receipts/boot`, not Settings (none exists);
(d) the `ToolRunner` refactor lands as an executor function on `Tools.Runner` with `Effects.Runner` as the seam
implementation, so the boundary table's arrow (Effects depends on Tools) holds without a cycle.

## Research, 2026-09-20, and the G1 amendments it produces

The owner asked for the design to be checked against what the field does, not against this tree's own plan.
Read this date, primary sources only; each amendment names the line of the G1 plan it changes.

1. **DSSE (secure-systems-lab/dsse, protocol.md).** The signature is over `PAE(UTF8(PAYLOAD_TYPE),
   SERIALIZED_BODY)` where PAE is `"DSSEv1" SP LEN(type) SP type SP LEN(body) SP body`, so the payload type is
   inside the signed bytes: "two different applications could use the same encoding (e.g. JSON) but interpret the
   payload differently". `KEYID` is "an unauthenticated hint" that "MUST NOT be used for security decisions".
   **Amendment A (lines 2, 3, 4):** the signature is over `PAE("trinity/receipt/" <> scheme, canonical_body)`, the
   DSSE construction with the scheme string as the payload type, and the checkpoint signature over
   `PAE("trinity/checkpoint/" <> scheme, canonical_checkpoint)`. The reason is concrete here: SLICE.md amendment 1
   has one key-custody module signing both receipts and, at 061, the MCP core's envelopes with the same key, and
   without domain separation a signature made for one could be presented as the other. `key_id` stays inside the
   body as SLICE.md amendment 3 says, which is stronger than DSSE's hint; the verifier still treats it only as
   the registry lookup key and takes the algorithm from the registry row.
2. **RFC 8725, JWT Best Current Practices, section 3.1.** "Libraries MUST enable the caller to specify a supported
   set of algorithms and MUST NOT use any other algorithms", and "each key MUST be used with exactly one
   algorithm, and this MUST be checked when the cryptographic operation is performed". **Amendment B (line 4):**
   the verifier takes the allowed scheme set as an argument (the three schemes, or fewer), the registry row binds
   one algorithm to one key id, and a receipt whose scheme names an algorithm other than its key's row is
   refused before any signature check, which is SLICE.md amendments 3 and 4 with the RFC's wording as the test
   names.
3. **RFC 7638, JWK Thumbprint.** A key identifier computed by anyone from the public key: the required JWK
   members (`crv`, `kty`, `x`, `y` for EC; `crv`, `kty`, `x` for OKP per RFC 8037) serialised "with no whitespace
   ... ordered lexicographically", hashed with SHA-256, base64url. **Amendment C (line 2):** `key_id` is the RFC
   7638 thumbprint of the public key, and the registry row carries the JWK, so a stranger recomputes the id from
   the key instead of trusting a label. ML-DSA-87 has no JWK form registered at this date; its id is the SHA-256
   of the raw public key with the same base64url encoding, and the registry row says so by a `kid_scheme` field.
4. **RFC 5848, Signed Syslog Messages.** The existing standard for signing a stream of records in groups: a
   Signature Block carries a Reboot Session ID (RSID, "expected to strictly monotonically increase"), a Global
   Block Counter, the First Message Number, a Count of hashes, the hashes, and a signature over the block; blocks
   are emitted by count or by `sigMaxDelay`. **Amendment D (line 3):** the `receipt_checkpoints` row carries
   `chain_scope`, `boot_receipt_hash` (the RSID's role: which boot this checkpoint belongs to), `first_seq`,
   `last_seq`, `tail_hash`, `key_id`, `signature`, `at`, so a checkpoint states its coverage and a gap between
   checkpoints is visible as a gap, not as silence; N = 100 rows or T = 5 s stands (RFC 5848 caps a block at 99
   hashes because of syslog message size, a limit this table does not have).
5. **C2SP `tlog-checkpoint` and `signed-note`.** "Verifiers MUST ignore signatures from unknown keys ... If no
   known key successfully verifies, clients MUST reject the note"; "A log MUST not sign any checkpoint which is
   inconsistent with any checkpoint it previously signed". **Amendment E (lines 3, 4):** the verifier's exit 5
   (trust not established) is exactly the first rule and is stated with it; the ChainWriter, on rehydrate,
   verifies the newest checkpoint against the tail before re-signing it, so it can never sign a checkpoint
   inconsistent with one it signed before (a test: a tail row altered on disk stops the writer from starting,
   with the reason).
6. **Crosby and Wallach, "Efficient Data Structures for Tamper-Evident Logging" (USENIX Security 2009), and RFC
   9162.** A flat hash chain proves inclusion in O(n) and a history tree or Merkle tree in O(log n), with
   consistency proofs between two tree heads. **No amendment; the trade-off recorded:** Trinity's scopes are per
   session and verified wholesale, offline, by an operator holding the rows, so the linear chain with RFC
   5848-style checkpoints is the right size; the day a third party needs inclusion proofs without the rows (026's
   store-and-forward, or 061's MCP consumers), the checkpoint gains a Merkle root over the scope under a new
   scheme string, which this design leaves room for and does not build.
7. **FIPS 186-5 (NIST, February 2023) approves EdDSA.** OpenSSL's maintainers (openssl/openssl #22105, 2023-09):
   Ed25519 "could be changed to approved once the corresponding self tests are implemented", which later
   providers carry; the 3.0.7 module the 003 image runs does not, and OTP's `pkey.c` refuses `eddsa` in the mode
   on its own (measured on the leg). **No amendment; a note for the register:** the mode selection (P-384 when
   `info_fips()` is `enabled`) is the right rule for this OTP and this provider, and it lives in one function; when
   OTP lifts its refusal on a provider that approves Ed25519, that function changes and nothing else, because the
   registry binds each key to its algorithm and old chains verify as written.

What the research did not change: RFC 8785 canonicalisation (the tree already uses it, `jcs` 0.2.0, the RFC
8785 vector passes); one writer per scope (ADR-0013); signing every decision, effect, boot and cap receipt;
denial when no approved signer exists; the registry as the only source of the algorithm.
