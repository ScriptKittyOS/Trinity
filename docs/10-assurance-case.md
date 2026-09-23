<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# 10: Assurance case

An assurance case is a structured argument that a system's security claims hold, with the evidence
for each claim named so that a reader can check it rather than take it on trust. This document is
Trinity's.

It is organised as claims, each with the argument for it and the evidence that supports it. Every
piece of evidence is a path in this repository, a test that can be run, or a command that produces
the stated output. Where a claim has a limit, the limit is stated with the claim rather than left
for a reader to discover.

**The top claim.** *An action with an effect outside the conversation cannot happen unless a
decision was made to allow it, and what happened can be reconstructed afterwards from records that
cannot be silently altered.*

Everything below decomposes that claim. The scope is the software in this repository. It excludes
the machine's own security, the model provider's conduct, and any external authority layer a
deployment supplies, each of which is named as an assumption at the end.

---

## C1. No effect happens without a decision

**Argument.** Every tool call is decided before it runs. The decision is made by one component,
recorded before the effect is attempted, and cannot be bypassed by the surface that requested it:
approval surfaces carry no authority of their own, they only report a decision made elsewhere.

**Evidence.**
- `lib/trinity/permissions/gate.ex` is the single decision point; `lib/trinity/effects/runner.ex`
  asks it once per validated call and writes a decision receipt before anything runs.
- A decision that cannot be receipted refuses the call, so an unrecorded effect is not a
  possibility the code allows.
- `test/trinity/permissions/gate_test.exs`, `test/trinity/permissions/session_flow_test.exs`.
- The tier of a call is code, not configuration supplied by a caller: a runtime-registered tool
  cannot claim a core tool's name or lower its own tier.

**Limit.** The gate decides; it does not sandbox. A tool that is allowed to run does run, with the
privileges of the operating-system user. Isolation of executable content is a separate mechanism
(`Trinity.Sandbox`) and is not claimed here.

## C2. Identity is separated from authority

**Argument.** Establishing who is calling and deciding whether an effect may happen are different
questions answered by different components. A credential never carries an entitlement.

**Evidence.**
- ADR-0008 records the decision and its consequences.
- `Trinity.MCP.Auth` authenticates a caller and answers with a principal, never a permission; the
  permission gate still decides every call that principal makes.
- A token's scopes are checked *before* the gate is consulted and never in place of it: a scoped
  token is permission to ask, not permission to act
  (`test/trinity/mcp/auth/resource_server_test.exs`).
- An approval arriving from a chat channel is capped below what the local desktop may approve, and
  the cap is applied *after* the gate's own decision, never instead of it
  (`lib/trinity/gateways/cap.ex`, `test/trinity/gateways/approvals_test.exs`).

**Limit.** Where a deployment supplies an external authority layer, this tree keeps no executor for
the effects that layer governs; what that layer decides is outside this case.

## C3. Content from outside the machine is never treated as instruction

**Argument.** Anything Trinity reads from the world — a web page, a file, a tool result, another
agent's response over the protocol — is marked at the boundary where it enters and stays marked.
The model sees it as data.

**Evidence.**
- `lib/trinity/tools/untrusted.ex` marks content at the boundary with its origin and source.
- The persona instructs that tool results and web pages are data and never instructions, and the
  provenance rules in `docs/07-security-model.md` state where the mark is applied.
- Model output reaches the interface through one rendering path, so an injection cannot escape
  into markup by a second route.

**Limit.** Marking is not proof against a model choosing to follow instructions it was told to
ignore. The mitigation that does not depend on the model's judgement is C1: whatever the model is
persuaded to attempt still meets the gate.

## C4. Model output is never executed

**Argument.** No path evaluates text a model produced. This is enforced by a tool over the whole
tree rather than by review.

**Evidence.**
- `credo_checks/no_eval_on_model_output.ex`, a project-specific static analysis rule covering
  `Code.eval_string` and its family, run in the quality gate on every commit.
- `test/no_eval_on_model_output_test.exs` holds the rule itself.
- `docs/03-conventions.md`, engineering rules.

## C5. The architecture is enforced rather than described

**Argument.** The module layering in `docs/01-architecture.md` is compiled. A dependency that
violates it is a compile error, so the document cannot drift from the code.

**Evidence.**
- `boundary` runs as a compiler and the gate compiles with warnings as errors, so a violation fails
  the build.
- The authorization package is declared with no dependency on the rest of the tree, and the
  refusal of a planted violation is reproducible: add a call to `Trinity.Sessions` inside
  `lib/trinity/mcp/auth/` and `mix compile --warnings-as-errors` exits 1 naming it.
- `test/trinity/mcp/auth/boundary_test.exs` holds the declaration and a source census beside it.

## C6. What happened can be reconstructed

**Argument.** Decisions and effects are written to an append-only hash chain, each entry signed,
with periodic checkpoints, and a verifier that detects alteration.

**Evidence.**
- `lib/trinity/receipts/` — the chain writer, the signer (Ed25519), checkpoints, and
  `verifier.ex`.
- `test/trinity/receipts/verifier_test.exs` and `standalone_verifier_test.exs`: the verifier
  detects a tampered entry, and it runs without the application so an auditor need not trust the
  program that wrote the records.
- Receipts carry the caller's issuer, subject and scope where the call arrived over the protocol,
  and never the credential itself.

**Limit, stated plainly.** A chain signed by a key held in a file proves the records were not
altered after the fact. It does not prove custody of the key. Key custody is a separate concern
and is not claimed here.

## C7. Cryptography is standard, correctly sourced, and measured

**Argument.** Only published, reviewed algorithms are used; none is implemented in this project;
keys and nonces come from a cryptographically secure generator; and the claims about approved
algorithms are measured on a dedicated build rather than asserted.

**Evidence.**
- Ed25519 (RFC 8032), SHA-256 (FIPS 180-4), AES-256-GCM (NIST SP 800-38D), and the JOSE algorithms
  ES256, EdDSA and RS256 (RFC 7518, RFC 8037). All performed by Erlang/OTP's `:crypto` (OpenSSL)
  and the JOSE library.
- All keys, nonces and credentials from `:crypto.strong_rand_bytes/1`. A census test forbids the
  non-cryptographic generator in the gateway package
  (`test/trinity/gateways/identities_test.exs`), added after an audit found a pairing code drawn
  from `Enum.random/1`; the fix is in the history and is not hidden.
- A continuous integration leg builds from source and runs the cryptographic properties inside a
  FIPS-mode container (`docs/fips-leg.md`, the `fips` job).

## C8. The supply chain is controlled and the provenance of changes is established

**Argument.** Dependencies are pinned and audited; what is in a build is enumerated in the build;
where a released binary came from can be checked by whoever holds it; every change carries an
attested author; and no change reaches the main branch without the full gate.

**Evidence.**
- Versions pinned in `VERSIONS.md` and verified against the lock file by the gate; `hex.audit` and
  `deps.audit` run on every commit.
- A CycloneDX bill of materials is generated by the gate on every commit (`mix trinity.sbom`) and
  uploaded with each platform's artifacts, so whoever has the binary has the list of what is in
  it. The bill states its own coverage in a `metadata.properties` entry rather than in a document
  beside it.
- Each released artifact carries build provenance attested through GitHub's workflow identity and
  recorded in a public transparency log, and `gh attestation verify` checks it in the same job
  that produced it, with its output in the run summary. An attestation nobody checks is a file
  rather than an assurance.
- Every commit carries a Developer Certificate of Origin sign-off, enforced by a local hook and
  independently by CI, so a bypassed hook still fails the build.
- The main branch is protected: changes merge only through a pull request with the gate green.

**Gaps, stated rather than omitted.** Two remain, and they are narrower than the one this document
stated before slice 002 rather than absent.

- The bill covers Hex dependencies resolved from `mix.lock` and does not cover the Rust crates the
  desktop shell links. A reader who misses the coverage property would conclude there is no Rust
  in the product, which is false. Slice 121 adds the crate half.
- The bill is not itself signed with a project-held key, and releases are not signed. Provenance
  establishes where a binary was built; it does not establish that the project intended to publish
  it. Signing is slice 101, and until it exists this claim is weaker than current federal guidance
  asks for.

## C9. Memory safety by construction

**Argument.** The classes of defect that dominate vulnerability data in memory-unsafe languages do
not arise in this tree, because of the languages it is written in rather than because of diligence.

**Evidence.** The application is Elixir on the BEAM; the desktop shell is Rust. Both are
memory-safe. There is no C or C++ in the project's own code.

**Limit.** Dependencies below the runtime — OpenSSL, the BEAM itself, the GTK stack the desktop
shell links — are written in memory-unsafe languages. The claim is about this project's code.

## C10. Secrets do not enter the repository or the records

**Argument.** Credentials live in the environment or the operating system's keychain, never in the
tree, and are kept out of the records the system writes.

**Evidence.**
- A secrets scan runs in the quality gate on every commit; `.env*` is excluded from version
  control.
- No credential material reaches a receipt, a log line, or the model's context: the authorization
  layer answers with a principal and never the token, and tests scan the records and the session's
  messages for credential material and find none.

---

## Assumptions

An assurance case that does not name its assumptions is an advertisement. These are Trinity's, and
each is outside the software's control.

1. **The machine is trusted.** Trinity runs as the operator's user and protects them from what it
   reads, not from themselves or from an attacker who already controls the machine.
2. **The BEAM is not an operating-system sandbox.** It isolates processes from each other; it does
   not confine what a permitted tool may do to the filesystem or the network.
3. **Key custody is the operator's.** See the limit under C6.
4. **The model provider is not trusted for safety.** Every claim above is arranged so that a model
   behaving badly is contained by the gate and the membrane rather than by its own compliance.
5. **An external authority layer, where a deployment supplies one, is outside this case.**

## What is not claimed

`SECURITY.md` states the boundaries in the project's own words. In summary: no claim is made about
resistance to an attacker with local privileges, about the sandboxing of executable content before
the sandbox slice, or about any regulatory compliance not carrying a row in
`docs/09-standards-register.md` with an evidence path and a status.

## How to check this document

Every claim above names files, tests or commands. `mix gate` runs the checks referenced throughout
in one command. The standards register records which external requirements are claimed and which
are not, and the risk register records what is known to be wrong and what would lift it. If a
claim here cannot be checked by a reader from those artefacts, that is a defect in this document
and worth reporting as one.
