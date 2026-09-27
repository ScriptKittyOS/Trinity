<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Cryptographic inventory

Every cryptographic capability Trinity uses, the module that calls it, and what is underneath.

**Read the certificate column carefully.** Trinity implements no cryptography of its own. Every
primitive is OTP's `:crypto`, which calls the OpenSSL the host provides. A CMVP certificate belongs
to that provider, on that host, not to this software. **Anything not established from a document is
`UNKNOWN` and stays `UNKNOWN`.**

## The table

| Capability | Trinity module | Underlying | CMVP cert | Notes |
|---|---|---|---|---|
| Receipt signing, default | `lib/trinity/receipts/signer/ed25519.ex` | `:crypto.sign(:eddsa, :none, …, :ed25519)`, line 21 | **UNKNOWN** | Ed25519, RFC 8032. `available?/0` line 14 returns false when `:crypto.info_fips() == :enabled`, so it is not selected in FIPS mode |
| Receipt signing, FIPS mode | `lib/trinity/receipts/signer/p384.ex` | `:crypto.sign(:ecdsa, :sha384, …, :secp384r1)`, line 25 | **UNKNOWN** | ECDSA P-384 with SHA-384. Selected when the mode is enabled |
| Receipt signing, opt-in | `lib/trinity/receipts/signer/mldsa87.ex` | `:crypto` ML-DSA-87, FIPS 204 | **UNKNOWN** | Never the default. `available?/0` line 24 checks `:mldsa87 in :crypto.supports(:public_keys)` |
| Receipt hashing | `lib/trinity/receipts/envelope.ex:36` | `:crypto.hash(:sha256, …)` | **UNKNOWN** | Over the DSSE pre-authentication encoding, not the bare payload |
| Merkle tree over a chain | `lib/trinity/receipts/merkle.ex` | `:crypto.hash(:sha256, …)` | **UNKNOWN** | RFC 6962 hashing: distinct leaf and node prefixes, odd nodes promoted not duplicated |
| Blob encryption at rest | `lib/trinity/vault.ex:180` | `:crypto.crypto_one_time_aead(:aes_256_gcm, …)` | **UNKNOWN** | Fresh 256-bit data key per blob, `docs/encryption-at-rest.md` |
| Data key wrapping | `lib/trinity/keys/local.ex:179` | `:crypto.crypto_one_time_aead(:aes_256_gcm, …)` | **UNKNOWN** | The key encryption key wraps the data key beside the ciphertext |
| Key derivation from a passphrase | `lib/trinity/keys/local.ex:280` | `:crypto.pbkdf2_hmac(:sha512, …)`, 600,000 iterations (line 57) | **UNKNOWN** | Only when `TRINITY_KEYS_PASSPHRASE` is set |
| Sub-key derivation | `lib/trinity/keys/local.ex:415` | `:crypto.mac(:hmac, :sha256, …)` | **UNKNOWN** | |
| Key id | `lib/trinity/keys/local.ex:226` | `:crypto.hash(:sha256, "trinity/key-id" <> root)` | Not applicable | An identifier, not a secret |
| MCP request state envelope | `lib/trinity/mcp/server/envelope.ex:49` | `:crypto.crypto_one_time_aead(:aes_256_gcm, …)` | **UNKNOWN** | Slice 061, key in the keys directory |
| Device identifier | `lib/trinity/receipts/clock.ex` | `:crypto.strong_rand_bytes/1` | Not applicable | Random, names nothing about the host |
| JWK thumbprint | `lib/trinity/receipts/signer.ex` | `:crypto.hash(:sha256, …)` | Not applicable | RFC 7638 |
| Canonical JSON | `lib/trinity/receipts/envelope.ex:15` | `Jcs.encode/1` | Not applicable | RFC 8785, not a cryptographic primitive |

## Why every certificate says UNKNOWN

Because the honest answer depends on the host, and this repository cannot know it.

`docs/fips-leg.md` is the only place a certificate number appears in this tree, and it appears with
a qualification that this inventory repeats rather than softens. From `docs/fips-leg.md:53-59`:

> Red Hat's page, https://access.redhat.com/compliance/fips, read 2026-09-20, lists for Red Hat
> Enterprise Linux 9.8 the module "OpenSSL", version `3.0.7-395c1a240fbfffd8`, CMVP certificate
> #4857, status "Active". The version string the image reports and the version string the page
> lists differ in their build hash. Trinity does not claim they are the same binary, and does not
> claim a validation. What the leg establishes is narrower and exact: the gate and the suite run
> with OTP in FIPS mode against the FIPS provider that this distribution ships and names, with the
> algorithms the mode removes listed below. Whether a deployment's provider is a validated one is
> that deployment's question, answered from the certificate and the running binary, not from this
> file.

So: **certificate #4857 is the certificate of a Red Hat module**, cited for your convenience in
checking your own host. It is not Trinity's certificate, it does not travel with this software, and
on a different distribution it is irrelevant.

## What the FIPS leg does establish

`docs/fips-leg.md`, and the `fips` job in `.github/workflows/gate.yml`:

- The full gate and test suite run with OTP in FIPS mode, on every push, in a container built from
  `ci/fips/Containerfile`.
- The mode is entered by `ERL_AFLAGS="-crypto fips_mode true -eval application:load(crypto)"`.
- The algorithms the mode removes are listed in that document, and the signer selection responds:
  Ed25519 reports unavailable in the mode (`lib/trinity/receipts/signer/ed25519.ex:14`) and P-384 is
  selected instead.

That is a statement about behaviour under a mode. It is **not** a validation, and no part of this
repository should be cited as one.

## What an assessor should do with this page

1. Establish which OpenSSL provider your host actually loads, and its certificate, from the running
   binary. Not from this file.
2. Decide whether Ed25519 is acceptable in your boundary. If it is not, run in FIPS mode and the
   selection changes by itself.
3. Note that **key custody is not addressed by any row above.** The default is a 0600 file
   (`lib/trinity/paths.ex`), the seam for a KMS or HSM exists (`lib/trinity/keys.ex`), and **no KMS
   or HSM adapter is in the tree**.
4. Note that **ML-DSA-87 is never selected by default** and requires the linked OpenSSL to carry it.
