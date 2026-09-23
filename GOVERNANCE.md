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

There is no committee to join yet. The path, when it opens:

1. Land changes through the ordinary review process, with evidence that meets the proof
   standard in `docs/03-conventions.md`.
2. Review someone else's slice and have that review hold up.
3. The maintainer proposes commit access; it is recorded here and in `MAINTAINERS.md`.

Commit access carries the same obligations as authorship: the rules of evidence in
`docs/03-conventions.md`
apply to everyone, and "verified" always names its command and its exit code.

## Changing this document

By ADR, like anything else.
