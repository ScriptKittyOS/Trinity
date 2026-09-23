<!-- SPDX-License-Identifier: Apache-2.0 -->
# Governance

## Today

**One maintainer**, named in `MAINTAINERS.md`, who is also the author and the sole reviewer.
Every change is gated on that person's review. This is stated rather than dressed up: the
review queue is the project's real critical path.

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
