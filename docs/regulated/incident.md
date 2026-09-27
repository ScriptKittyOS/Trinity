<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Incident reporting

Clocks that may apply when Trinity is inside an accredited boundary, and what the software gives you
to work with. **The reporting obligation is the lab's, not this project's.** Trinity is customer
controlled software; there is no provider-side incident process that runs on your behalf.

## CONTACT = TODO

**This pack does not yet name a contact.** Fill this in before the pack is used in an assessment:

| Role | Contact |
|---|---|
| Lab incident response lead | TODO |
| Contracting officer or COR | TODO |
| Privacy official, if PHI is in scope | TODO |
| Security reports about this software | `SECURITY.md` in this repository |

Leaving these as TODO is deliberate. An invented name is worse than a blank, because a blank gets
filled and a wrong name gets used.

## The 72-hour DFARS clock

If the lab holds a contract with **DFARS 252.204-7012**, a cyber incident affecting a covered
contractor information system, or the covered defense information on it, is **reported to DoD within
72 hours of discovery**, through the DoD reporting mechanism. A medium assurance certificate is
required to submit. The clock runs from discovery, not from confirmation, and the obligation is the
contractor's.

**What Trinity contributes:** a signed, hash-linked record of every governed action, with the
verifier in `receipts-verify.md`. That is evidence for the report. It is not the report, and
producing it does not start, stop or satisfy the clock.

**What Trinity does not do:** it does not detect an incident, does not notify anyone, and does not
ship logs anywhere. Forwarding is **NOT IN TREE** (`customer-responsibility-matrix.md`, Incidents).

## The HIPAA clock, if PHI is in scope

If PHI is in scope, the Breach Notification Rule applies to the covered entity: individuals without
unreasonable delay and **no later than 60 days** from discovery, the Secretary on the same clock for
a breach of 500 or more individuals, and annually otherwise.

Two things to be clear about before relying on that paragraph:

1. **This pack is not a HIPAA attestation** and nothing in this repository has been audited against
   the Security Rule.
2. **Sudo Apt Holdings LLC is not your Business Associate** by virtue of you running this software.
   Running a binary on your own host does not create the relationship, and no BAA is offered here.

Whether an event is a breach under 45 CFR 164.402, including the risk assessment, is the covered
entity's determination.

## What the software gives you at the moment of an incident

| Need | What exists | Path |
|---|---|---|
| A record of what was decided and done | Signed hash chain, per scope | `lib/trinity/receipts/chain_writer.ex` |
| Verify that record without trusting the app | Standalone verifier and a mix task | `receipts-verify.md` |
| Know the signer was unavailable | Alarm, and every effect denied until a signer returns | `lib/trinity/receipts/alarm.ex` |
| Subscribe to events | Telemetry, documented | `docs/telemetry.md` |
| Take a copy of the whole state | `mix trinity.export` | `docs/backup.md` |
| Know which code paths can cause an effect | Published, closed population | `docs/effects-catalog.md` |

## What the software does not give you

- **No intrusion detection.** Trinity does not decide that something bad happened.
- **No alerting.** It emits telemetry; collecting and alerting on it is yours.
- **No log shipping.** NOT IN TREE.
- **No third-party witness.** Nothing outside the host attests to the chain, so a reader who does not
  trust the host cannot detect backdated forgery. NOT IN TREE, and stated in
  `authorization-boundary.md`.
- **No tamper alarm on the store itself.** The chain is verifiable on demand; nothing watches it
  continuously.

## A note on the clock and the clock

The receipt clock is the host's own reading (`lib/trinity/receipts/clock.ex`). It never goes
backwards within a chain, and it is signed, so the ordering cannot be edited afterwards by anything
that cannot sign. It is **not** a trusted timestamp and must not be offered to an investigator as
one. If your incident process needs authoritative time, supply a trusted time source; the standards
register records that as a deployment dependency rather than a property of this tree
(`docs/09-standards-register.md`).
