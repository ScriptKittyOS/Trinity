<!-- SPDX-License-Identifier: Apache-2.0 -->
# Contributing

## Before anything

```
git config core.hooksPath .githooks
```

`.githooks/commit-msg` strips assistant attribution trailers. `scripts/plan_check.sh` checks
the history too, so an unconfigured hook fails the gate rather than passing quietly.

## The rules that actually bind

`CLAUDE.md` is the contract; `docs/04-slice-process.md` is the process. The short version:

- **One slice at a time**, on `slice/NNN-short-name`. Do not widen scope.
- **`mix gate` must pass before every commit**, and `scripts/plan_check.sh` with it.
- **Every commit is signed off** (`git commit -s`). The hook and the gate refuse otherwise.
- **Proof means the command you ran and the output it produced.** Not a summary of it, not a
  reformatted digest inside a `$` block. A "verified" names its command and its exit code.
- **Populations derive from the tree.** Any "every X" names the command that enumerates X.
- **Corrections append.** Records are never rewritten; a wrong line stays and is corrected
  below it, saying what it supersedes.
- **A red before a fix.** A test for a claimed property is committed failing first, by name.

## Setup

```
asdf install          # reads .tool-versions
mix setup
mix gate
```

## What gets a change rejected

An unproven claim. A count typed rather than derived. A skip without a stated reason. A rule
added as prose where an enforcer was possible.
