<!-- SPDX-License-Identifier: Apache-2.0 -->
# Governance

## Today

**Three maintainers**, named in `MAINTAINERS.md`. Any of them may review a change, merge it, tag it
and cut a release. Every change still lands through a pull request against a protected branch with
the full gate green, which is the rule that has not changed and is not going to.

This is stated rather than dressed up. The project went from one maintainer to three on 2026-09-23,
and names in a file are not the same thing as people who have carried the work. What is true today
is that the project no longer stops if any one person does. What is not yet true is that any of
them could pick up any part of it cold: every commit in the tree to date has one author.
`docs/06-risk-register.md` R22 tracks that difference and states what would close it.

## Continuity

If any one maintainer becomes unavailable, for any reason, the others hold the access needed to
keep the project running: each can create and close issues, accept proposed changes, and publish a
release. Nothing in the ordinary workflow requires a specific individual.

Access is not given informally. Every account with write access to the repository must have
two-factor authentication enabled, and the organisation enforces that rather than asking for it:
an account without it loses access instead of being reminded. This is a requirement on the people
who can change what this project ships, and it is stated here because a project whose maintainers
can be phished has no supply chain integrity regardless of what the rest of this document says.

The exceptions are named here rather than left to be discovered. Administration of the GitHub
organisation, the domain, and the security mailbox rest with the author. Restoring those to a
surviving maintainer is a legal and administrative matter, not a technical one, and it is the first
thing a reader evaluating this project's continuity should ask about.

## Decisions

Anything that changes architecture, stack, data model or process gets an ADR in `docs/adr/`,
with a status of `proposed`, `accepted`, or `superseded by ADR-XXXX`. Decisions are recorded
before they are implemented, and corrections are **appended**: an ADR is never rewritten to
look as though it had always been right.

## Becoming a committer

**As it actually stands.** There are three maintainers (`MAINTAINERS.md`), two of whom joined on
2026-09-23 by the author's invitation rather than through the path below, because at that point
there was no history of outside contribution for the path to be applied to. That is written down
rather than smoothed over: the process described here has not yet been used, and a reader assessing
this project's governance should know which of its statements are practice and which are policy.

The path, for anyone joining from here:

1. Land changes through the ordinary review process, with evidence that meets the proof
   standard in `docs/03-conventions.md`.
2. Review someone else's slice and have that review hold up.
3. A maintainer proposes commit access; it is recorded here and in `MAINTAINERS.md`.

A maintainer can accept a proposed change, close an issue and cut a release. Administration of the
GitHub organisation, the domain and the security mailbox rest with the author alone, which is the
first thing a reader should ask about and the reason it is named here rather than left to be
discovered. Two-factor authentication is required of everyone with write access, enforced by the
organisation rather than asked for in a document.

Commit access carries the same obligations as authorship: the rules of evidence in
`docs/03-conventions.md`
apply to everyone, and "verified" always names its command and its exit code.

## Changing this document

By ADR, like anything else.
