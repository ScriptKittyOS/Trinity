<!-- SPDX-License-Identifier: Apache-2.0 -->
# Contributing

Trinity is pre-alpha with one maintainer, and the work is planned as numbered slices
(`ROADMAP.md`). The most useful contributions right now are bug reports against a tagged slice,
corrections to the documents, and review of a slice's proof. If you want to build a slice, open
an issue naming it first so two people do not build the same one.

## Setup

```
asdf install                          # reads .tool-versions
git config core.hooksPath .githooks   # the commit-msg hook; see below
mix setup
mix gate
```

`mix gate` has to exit 0 before every commit. It is the same command locally and in CI.

## The rules that bind

`CLAUDE.md` is the engineering contract and `docs/04-slice-process.md` is the process. The
short version:

- **One slice at a time**, on a branch named `slice/NNN-short-name`. Do not widen its scope; write
  anything you find outside it under "Follow-ups" in that slice's `NOTES.md`.
- **`mix gate` passes before every commit**, including `scripts/plan_check.sh`.
- **Every commit is signed off** (`git commit -s`, the Developer Certificate of Origin). The hook
  and the gate refuse a commit without it.
- **No attribution trailers in commit messages.** `.githooks/commit-msg` strips them, and
  `plan_check` checks the history itself, so an unconfigured hook fails the gate rather than
  passing quietly. Commit messages also carry no issue-tracker identifiers.
- **Proof is the command you ran and the output it produced.** Not a summary of it. Anything
  described as verified names its command and its exit code.
- **Populations come from the tree.** Any claim about "every X" names the command that lists X.
- **Corrections are appended.** `PROOF.md`, `NOTES.md` and the decision records are never
  rewritten; a wrong line stays and is corrected below it, saying what it supersedes.
- **A failing test comes before the fix.** A test for a claimed property is committed failing
  first, by name, and the fix commit refers to it.

## Commit messages

Conventional Commits with the slice id as the scope:

```
feat(s012): session process with restart rehydration
test(s012): crash-recovery test for the session process
docs(s012): proof
```

The final commit of a slice reads `feat(s012): complete slice 012 (session process and agent loop)`
and includes `PROOF.md` and the `ROADMAP.md` status change. Slices merge to `main` with a merge
commit and are tagged `slice/NNN`.

## What gets a change sent back

An unproven claim. A count typed rather than derived. A skipped check without a stated reason.
A rule added as prose where an enforcer was possible. A version not listed in `VERSIONS.md`
(propose the newer one in `NOTES.md` instead of upgrading mid-slice).

## Reporting problems

Bugs and questions go in the issue tracker. Security reports do not; see `SECURITY.md`.
