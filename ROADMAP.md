<!-- SPDX-License-Identifier: Apache-2.0 -->
# Roadmap

What this project intends to do, and what it intends not to do, over the next year. Written for
someone deciding whether to depend on Trinity, review it, or contribute to it.

The unit of work is a **slice**: one increment small enough to review in a sitting, which ends with
a tag and an engineering record of what was built and what was proven. Milestones group slices.
Dates are deliberately absent, because a date this project could not hold would be worth less than
an order it can. What is here is the order, the meaning of each step, and what has to be true
before a step counts as done.

## Where the project is

Pre-alpha, and usable from source. Milestones **M0 through M5a** are approved, and the first slice
of M5b with them. There is no released binary yet: packaged binaries are built and smoke-tested on
Linux, macOS and Windows on every change that touches the packaging inputs, but nothing is
published for general use until the release pipeline in M6 signs it.

## Next, in order

| Milestone | What it means | Status |
|---|---|---|
| **M5b Reaches** | Messaging gateways, so a conversation can start from a channel rather than the desktop, and subagents | in progress |
| **M6 Ships** | Observability and a cost ledger, the native desktop shell, and a **signed release pipeline** | next |
| **M7 Sandboxed** | Skills that execute, inside an in-VM sandbox rather than on trust | after M6 |
| **M9 Donatable** | Open-source hygiene audited end to end, the supply chain signed, the shared libraries extracted for reuse | continuous, closing after M7 |

Milestones M0 to M5a are complete and are described in the [Milestones](README.md#milestones)
table in the README, together with what each one had to demonstrate before it was accepted.

### The three things that matter most in the next year

1. **A signed release.** Today the project produces build provenance for every packaged artifact,
   attested through the build's own identity and verifiable by whoever holds the binary. It does
   not yet sign a release with a project-held key, and it publishes no release. Both arrive in M6.
   Until then, the honest description of this project is "buildable from source", not "shipped".
2. **An in-VM sandbox for executable skills.** The skills system can already extend itself behind
   approval and a scanner, but a skill that executes is a different class of risk from a skill that
   is read, and M7 is where that risk is contained by construction rather than by review.
3. **Extraction of the reusable parts.** The receipt chain, the permission gate and the MCP
   authorization layer are written to be liftable out of this tree. M9 lifts them, so that the
   useful parts of this work do not require adopting the whole of it.

## What this project will not do

These are decisions, not omissions, and they are not expected to change within the year.

- **No hosted multi-tenant service.** Trinity is single-user and local-first. The design does not
  preclude a hosted version; this project is not building one.
- **No training or reinforcement-learning pipeline.** Exporting trajectories may come later.
  Training on them is somebody else's project.
- **No mobile applications.**
- **No breadth of integrations at launch.** Depth first: a small number of gateways and tools that
  work completely, rather than many that work partly. A long list of half-supported integrations is
  a liability in a system whose whole argument is about what it will and will not do on your behalf.
- **No feature matched to another agent's feature list for its own sake.** Scope grows from what
  the security and assurance argument can support, not from comparison.

## How the order is decided, and how it changes

Slices are ordered by dependency, not by preference, and the order is recorded before the work
starts. Anything that changes the architecture, the stack, the data model or the process is
recorded as an architecture decision record in [`docs/adr/`](docs/adr) **before** it is
implemented, with a status of proposed, accepted, or superseded. Decision records are appended to
and never rewritten, so a decision that turned out wrong stays visible next to the one that
replaced it.

Detailed per-slice plans are working material and are not published; what is published is the
result: a tag, a commit that explains what was built, and the record of what was proven. See
[`GOVERNANCE.md`](GOVERNANCE.md) for who decides, and
[`docs/06-risk-register.md`](docs/06-risk-register.md) for the risks that could change this order,
each with what would have to happen for it to be closed.
