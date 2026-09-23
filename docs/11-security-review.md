<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# 11: Security review

**Review of 2026-09-23.** Conducted by the maintainers, against the security requirements in
`docs/07-security-model.md` and the boundary and threat model in `docs/10-assurance-case.md`.
Supported by the tools the build runs on every commit, but the findings below are the ones a
person found, because a review that only reports what a tool reports is a tool run with a date on
it.

This document is the record, not the certificate. It says what was examined, what was found, what
was done about each finding, and what remains open. A review with no findings would be evidence
that the review did not happen.

## Scope

**In scope.** The software in this repository: the agent core, the permission gate and effect
membrane, the receipt chain, the protocol client and server and their authorization, the messaging
gateways, the web interface, the build and its supply chain.

**Out of scope, and why.** The host operating system, the model provider's conduct, any external
authorization server a deployment supplies, and physical access to the machine. Each is named as an
assumption in `docs/10-assurance-case.md`; a review cannot establish properties of things it does
not control, and claiming otherwise would weaken the parts it can establish.

## Method

1. The security requirements were read as claims and each was traced to the code that implements
   it and the test that holds it. Claims C1 to C10 in the assurance case are the result.
2. The trust boundary was walked in both directions: what crosses inward and where it is labelled;
   what crosses outward and what decided that it could.
3. The threat model's five adversaries were taken in turn and the tree examined for what each would
   try. This is where the findings below came from.
4. Tool output was read as input to the review rather than as its conclusion: the compiler with
   warnings as errors, the architectural boundary checker, Credo in strict mode, Sobelow, the
   dependency and licence audits, and a CycloneDX bill validated against the specification.

## Findings

Ordered by what they cost, not by when they were found. Every one of these is a defect a human
found in something that was passing its tests at the time.

### F1. Release-only compile failure, shipped and tagged (resolved)

**Severity: high. Class: build integrity.** A plug's `authorize:` option was an anonymous function.
`Plug.Builder` calls `init/1` at compile time under `MIX_ENV=prod` and escapes the result, and a
closure cannot be escaped, so the production build failed while every test passed: the gate ran in
`:test`, where `init/1` is per request. The defect reached a tag before anything caught it.

**Resolved.** Replaced with a captured public function, with a regression test that runs
`Macro.escape/1` over `Plug.init([])`. More usefully, the *class* was closed: `mix gate` now runs
`scripts/prod_check.sh`, which compiles `:prod`, assembles a release and evaluates it, so a
production-only defect fails on the branch that introduces it.

**What it says about the review:** the gap was not in the code but in what the build exercised. A
test suite that never runs the configuration a user gets is not testing the product.

### F2. Pairing codes from a non-cryptographic generator (resolved)

**Severity: medium. Class: authentication.** Gateway pairing codes were generated with
`Enum.random/1`, which draws from a pseudo-random source that is not cryptographically secure. A
pairing code is what stands between an unknown account and a session.

**Resolved.** `:crypto.strong_rand_bytes/1` over a 32-character alphabet, so that `256 rem 32 = 0`
and the mapping is unbiased, with a census test over the distribution. Found by reading the code
against the criterion for cryptographic randomness rather than by any tool.

### F3. An architectural boundary that was never enforced (resolved)

**Severity: medium. Class: architectural integrity.** `Trinity.MCP.Auth` declared `deps: []`,
which reads as "this package depends on nothing and can be extracted". It could not: a nested
sub-boundary inherits its ancestors' dependencies, so the declaration was a claim the compiler had
never checked.

**Resolved.** Declared `top_level?: true`, which makes the compiler enforce it. **The finding that
matters is not the fix:** a declaration that looks like an enforced constraint but is not is worse
than no declaration, because it stops people checking.

### F4. Workflow tokens broader than the work (resolved)

**Severity: medium. Class: supply chain.** Two build workflows declared no token permissions at
all and ran with the repository default, which grants read on every scope; a third granted a
package write at the workflow level, where it applied to every job it would ever have.

**Resolved.** All three declare `contents: read`, with writes declared by the individual job that
needs them, and a test now requires every workflow to declare a top-level block granting no write.
Found by acting on a Scorecard result rather than by reading it.

### F5. A bill of materials that no consumer could validate (resolved)

**Severity: low. Class: supply chain.** The first CycloneDX bill this project generated was not
valid CycloneDX. The generator emits a dependency's licence string as an SPDX identifier without
checking that SPDX defines it, and one dependency spells `BSD 2-Clause` where SPDX has
`BSD-2-Clause`. One field in one component of 132 invalidated the whole document.

**Resolved.** Identifiers SPDX does not define are recorded as licence names, which is where
CycloneDX puts a licence it cannot resolve, against a vendored copy of the enumeration the
validator itself uses. Found by running the official validator instead of asserting the format.

## Open

Recorded here and in `docs/06-risk-register.md` rather than closed. Each names what would close it.

### O1. No egress restriction by resolved address

**Severity: medium. Class: server-side request forgery.** Every web fetch passes the permission
gate, so a person decides each one and the decision binds the exact arguments. There is no egress
allow-list and no check on the address a host resolves to, so an approved fetch to a host resolving
to a private or link-local address is not blocked by construction. `Trinity.NetworkGuard` blocks
outbound connections during the test suite and **is not a production control**; an earlier draft of
the assurance case described it as one, and that was corrected.

**Closes when:** the fetch tool resolves the host and refuses private, loopback, link-local and
unique-local destinations unless a deployment opts in, with a test that a redirect to such an
address is refused as well as a direct request.

### O2. An advisory in a transitive dependency of the desktop shell

**Severity: low, scoped. Class: dependency.** `glib` 0.18.5 carries GHSA-wrw7-89jp-8q8g. It is
transitive through the GTK stack the desktop framework requires on Linux and is not fixable by a
direct bump. **Scope was established rather than assumed:** the headless release ships no desktop
shell, so a server deployment does not carry it. Recorded as R25.

**Closes when:** a desktop framework release resolves `glib` 0.20 or later.

### O3. Releases are not signed

**Severity: medium at first release, none today. Class: distribution.** Every packaged artifact
carries build provenance attested through the build's own identity and recorded in a public
transparency log, which establishes where bytes were built. Nothing establishes that the project
intended to publish them, because the project publishes no releases yet.

**Closes when:** the release pipeline signs artifacts with a project-held key whose private half is
not on the distribution host, with a documented verification procedure. Until then, publishing a
release would create the exposure rather than reveal it.

### O4. One reviewer

**Severity: medium. Class: process.** Every commit in the tree has one author. The build is the
only thing that has reviewed most changes, and a build cannot judge whether a change is worth
making. Two further maintainers now hold review and merge rights; the history does not yet show
them using it.

**Closes when:** reviews and merged changes from a maintainer other than the author appear in the
git history. Recorded as R22.

## What this review does not establish

It does not establish the absence of vulnerabilities, and no review does. It establishes that the
security requirements were read as claims, that each was traced to the code and the test that hold
it, that the boundary was walked in both directions, and that the findings above were acted on. The
next review should begin by checking whether the open items above are still open, and whether the
five findings stayed fixed.
