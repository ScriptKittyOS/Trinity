<!-- SPDX-License-Identifier: Apache-2.0 -->
# Contributing

Trinity is pre-alpha, with the maintainers named in `MAINTAINERS.md`. The most useful contributions right now are bug
reports against a tagged release, corrections to the documents, and review of the engineering
records behind a change. If you want to take on a larger piece of work, open an issue describing
it first, so two people do not build the same thing.

## Setup

```
asdf install                          # reads .tool-versions
git config core.hooksPath .githooks   # the commit-msg hook; see below
mix setup
mix gate
```

`mix gate` has to exit 0 before every commit. It is the same command locally and in CI.

## The rules that bind

`docs/03-conventions.md` carries the engineering rules, the proof standard and the rules of
evidence. The short version:

- **One change at a time**, on its own branch, with a stated scope. Anything found outside that
  scope is recorded as a follow-up rather than folded in silently.
- **`mix gate` passes before every commit.** It runs formatting, a compile with warnings as
  errors, the architectural boundary check, a release build check, Credo, Sobelow, the dependency
  and licence audits, the full test suite and a coverage floor.
- **Every commit is signed off** (`git commit -s`, the Developer Certificate of Origin). The hook
  and the gate refuse a commit without it.
- **No attribution trailers in commit messages.** `.githooks/commit-msg` strips them, and CI
  checks the history itself, so an unconfigured hook fails the build rather than passing quietly.
  Commit messages carry no issue-tracker identifiers.
- **Proof is the command you ran and the output it produced.** Not a summary of it. Anything
  described as verified names its command and its exit code.
- **Populations come from the tree.** Any claim about "every X" names the command that lists X.
- **Corrections are appended.** Engineering records and decision records are never rewritten; a
  wrong line stays and is corrected below it, saying what it supersedes.
- **A failing test comes before the fix.** A test for a claimed property is committed failing
  first, by name, and the fix commit refers to it.
- **Major new functionality comes with tests for it, in the same change.** This is a policy, not a
  preference: a change that adds behaviour and no test for that behaviour is incomplete, and the
  question a reviewer will ask is which test fails if the change is reverted. A fixed bug gets a
  regression test naming the defect. The full policy is the *Tests* section of
  `docs/03-conventions.md`.

## Commit messages

Conventional Commits, with a scope that identifies the unit of work:

```
feat(s012): session process with restart rehydration
test(s012): crash-recovery test for the session process
```

A unit of work merges to `main` through a pull request with the `gate` check green, merge-commit
method only, and is then tagged. `CHANGELOG.md` records what each tag delivered and how it was
verified.

## What gets a change sent back

An unproven claim. A count typed rather than derived. A skipped check without a stated reason.
A rule added as prose where an enforcer was possible. A dependency version not listed in
`VERSIONS.md`: propose the newer one for review rather than adopting it inside another change.

## Reporting problems

Bugs and questions go in the issue tracker. Security reports do not; see `SECURITY.md`.
