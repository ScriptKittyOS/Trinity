<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Trinity for a regulated lab: what this pack is, and what it is not

For an ISSM or an assessment team deciding whether Trinity can run inside an accredited boundary.
It is written to be checked, not believed. Every claim below names a path in this repository, and
anything without one says **NOT IN TREE**.

## Read this part first

**Trinity is customer-controlled software. It is not a cloud service and this project is not a CSP.**
You run the binary, on your host, in your boundary. There is no Trinity-operated control plane, no
Trinity tenancy, and no Trinity staff with access to your data. That is what makes the rest of this
pack short: most of the controls an assessor asks about are yours, because the software is yours to
run.

**Trinity is not FedRAMP authorized.** There is no FedRAMP package, no 3PAO assessment and no agency
ATO for this software. A FedRAMP authorization is a property of a service offering; this is not one.

**Trinity is not CMMC certified.** There is no C3PAO assessment of this project. CMMC certifies an
organization's handling of CUI, not a library or an application, so the certifiable thing is your
lab, not this repository.

**This pack is not a HIPAA attestation.** No SOC 2, no HITRUST, no third-party audit of any kind has
been performed on this software. Sudo Apt Holdings LLC is not a Business Associate by virtue of you
running this binary, and nothing here should be read as offering a BAA.

**NIST has not evaluated, certified or endorsed anything in this repository.** Where this pack cites
a CMVP certificate it is the certificate of an operating system's cryptographic module, named so you
can check it against your own running binary, and `docs/fips-leg.md` says in terms that Trinity does
not claim the binaries are the same.

## What the project does claim

Three things, each of which an assessor can verify from the tree rather than from this page.

1. **Every governed action is recorded in a hash-linked, signed chain**, and the chain can be
   verified by a reader who does not trust the program that wrote it. The verifier is
   `lib/trinity/receipts/verifier.ex`; the task is `lib/mix/tasks/trinity.receipts.verify.ex`;
   a standalone script that needs no application is `bin/verify_receipt.exs`. See
   `receipts-verify.md` in this directory.
2. **The set of code paths that can cause an effect is closed**, and that closure is asserted by a
   census over the tree rather than by intent. The boundary is `lib/trinity/effects.ex`; the
   published population is `docs/effects-catalog.md`.
3. **Standalone, Trinity decides, acts and records by itself**, which is a specific and limited kind
   of evidence. `authorization-boundary.md` in this directory states the limit rather than leaving
   it to be discovered.

## What this pack does not decide for you

Whether Trinity may process CUI or PHI in your boundary is your determination, not this project's.
`customer-responsibility-matrix.md` sets out which controls are yours, which are the software's, and
which belong to the host or the cloud account underneath it. `data-flow.md` states what may enter a
model prompt and what may not. Read both before the others.

## The files

| File | What it answers |
|---|---|
| `authorization-boundary.md` | What is inside the boundary, what is outside, and where the trust ends |
| `customer-responsibility-matrix.md` | Who owns each control: the software, you, or the host |
| `data-flow.md` | What may enter a prompt, and what must never leave the boundary |
| `incident.md` | Reporting clocks and who to contact |
| `receipts-verify.md` | How an assessor verifies the record without trusting the application |
| `crypto-inventory.md` | Every cryptographic capability, its module, and its certificate status |
| `headless-image.md` | How the container image is built and hardened, and the checks run against it |
| `stig-applicability.md` | The image's STIG applicability statement, generated from OpenSCAP's evaluation of it |

## Status of this pack

This directory is documentation only. It adds no code, changes no behaviour, and asserts no control
that is not already in the tree. `stig-applicability.md` is generated rather than written, and says
how. Where the tree does not implement something this pack names, the
row says **NOT IN TREE** rather than describing an intention.

This pack documents the gap; it does not close it.
