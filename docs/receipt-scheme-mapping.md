<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Trinity's receipts and RFC 9943

RFC 9943, *An Architecture for Trustworthy and Transparent Digital Supply Chains* (IETF SCITT,
Standards Track, June 2026), standardises the class of object Trinity's receipts belong to. This page
says exactly where Trinity sits relative to it, including the part that does not fit.

## The terminology, first, because it is a collision

SCITT uses two words that Trinity uses one of.

| SCITT | Issued by | What it asserts |
|---|---|---|
| **Signed Statement** | the Issuer | an identifiable, non-repudiable statement about an artifact |
| **Receipt** | a **Transparency Service** | a cryptographic proof that a Signed Statement is included in a Verifiable Data Structure |

A SCITT Receipt **MUST** carry inclusion proofs. Trinity operates no Transparency Service, maintains
no Verifiable Data Structure, and issues no inclusion proofs: it keeps a local, single-writer hash
chain with signed checkpoints.

**So what Trinity calls a receipt is, in SCITT's vocabulary, a Signed Statement.** Nothing Trinity
emits is a SCITT Receipt, and this project makes no such claim. The name predates the RFC in this
tree and is not being changed, because "receipt" is the right word for what it is to the person who
owns the machine; but a reader who knows SCITT should not have to work this out for themselves.

## Two scheme versions, since slice 026

`receipt_v2_<family>` is slice 024's and carries ten keys. `receipt_v3_<family>` is slice 026's and
carries eleven: the ten plus `clock`, a hybrid logical clock for relating two chains that ran during
a partition. New rows are written under `v3`; `v2` rows are still verified under `v2`, row by row,
under each row's own scheme.

That is a scheme bump rather than an edit: no byte signed under `v2` changed, and
`Trinity.Receipts.Signer.accepted_schemes/0` is what the verifier allows by default, so bumping the
version did not make previously signed rows unverifiable. The field list below is `v3`.

## The envelope Trinity signs with today

The signature is not over the canonical JSON directly. It is over DSSE's pre-authentication encoding
of a payload type and that JSON, where the payload type is `trinity/receipt/<scheme>`
(`Trinity.Receipts.Envelope.receipt_type/1`). So the envelope is already a published construct, just
a different one from SCITT's: DSSE rather than COSE. That matters for the last section.

## The field mapping

Trinity's signed payload is RFC 8785 canonical JSON of exactly these eleven keys
(`Trinity.Receipts.ChainWriter`, the `body` map):

`scheme`, `seq`, `chain_scope`, `prev_hash`, `kind`, `subject`, `decision`, `fingerprint`, `at`,
`key_id`, `clock`.

Under `receipt_v2_*` the same list without `clock`.

`subject_ref` and `meta` are columns on the row but are **not** in the signed payload, so they are
not covered by the signature and are not mapped below.

| Trinity | SCITT / COSE / CWT | Note |
|---|---|---|
| `scheme` | COSE `alg` (label 1) | Trinity's scheme names the signature and digest algorithms together; COSE separates them. |
| `key_id` | COSE `kid` (label 4) | Same role: which key, without saying which algorithm. |
| `at` | CWT `iat` | RFC 3339 here, epoch seconds there. |
| `kind` | COSE `content_type` (label 3) | Trinity's is a closed vocabulary of five (`Trinity.Receipts.Receipt.kinds/0`: `decision`, `effect`, `query`, `boot`, `cap`); COSE's is a media type. |
| `subject` | CWT `sub` (claim 2) | SCITT requires a single `tstr`; Trinity's signed `subject` is a map of references. Mapping it needs a canonical string form chosen, which is a decision, not a rename. |
| *(absent)* | CWT `iss` (claim 1), **required** | Trinity has no issuer field. A single-operator machine has one issuer and it is implied by the key, which is why it was never needed and is exactly what a standards-track reader would look for first. |
| `decision`, `fingerprint` | the statement payload | Domain content. SCITT does not constrain it. |
| `clock` | **no equivalent** | A hybrid logical clock (slice 026): `wall`, `counter`, `node`. SCITT has no notion of one because a transparency service supplies the ordering its receipts need. Trinity has no such service, so ordering across a partition has to travel in the statement, and it is signed for the reason the mapping document gives below: a merge that orders two chains by an unsigned field orders them by something any writer could rewrite. |
| `seq`, `chain_scope`, `prev_hash` | **no equivalent** | These are the hash chain. In SCITT the equivalent guarantee comes from a Transparency Service's Verifiable Data Structure and is carried in a Receipt's proofs, not in the statement. Trinity's chain is the whole of its tamper-evidence, and it is local. |

## Why the field names are not being renamed

The obvious next step looks like renaming Trinity's fields to their COSE and CWT equivalents so a
receipt "looks standard". That would be worse than leaving it, for one reason: **the object would
then read as conformant while not being conformant.** A reader who recognises `iss`, `sub`, `kid`
and `iat` has been told, by the shape of the thing, that this is a SCITT object, and will reasonably
expect the rest of SCITT: a Transparency Service, a verifiable data structure, inclusion proofs.
None of that exists here.

That is a claim made by appearance rather than by a row in `docs/09-standards-register.md`, which is
the specific failure this project's standards register exists to prevent.

**What would be real, rather than cosmetic**, is emitting the statement as a `COSE_Sign1` object with
CWT claims `iss` and `sub` in its protected header, in place of the DSSE pre-authentication encoding
described above. That makes a Trinity statement genuinely readable by a SCITT-aware verifier rather
than merely familiar-looking. It is a change of signing envelope, with a scheme bump and a
dual-reading verifier behind it, and it is a decision for the owner rather than a rename anybody can
do.

## What this page lets a reader conclude

- Trinity's receipts are **Signed Statements** in SCITT's sense, not Receipts.
- Their integrity comes from a local hash chain with signed checkpoints, not from a transparency log.
- Every element of the signed payload maps to a published construct except four: `seq`, `prev_hash`
  and `chain_scope`, which are the ones SCITT delegates to a service Trinity does not run, and
  `clock`, which exists for the same reason, since ordering across a partition is what a
  transparency service would otherwise provide.
- `subject_ref` and `meta` are unsigned row columns. Nothing should be inferred from them.
- No conformance to RFC 9943 is claimed, and none should be inferred.
