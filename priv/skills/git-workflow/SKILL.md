---
name: git-workflow
description: Commits, branches and pull requests in a repository the person is working in. Use when asked to commit, stage, branch, rebase, write a commit message, open a pull request, or inspect git history or status.
license: Apache-2.0
compatibility: Needs the shell tool with git on the machine.
metadata:
  author: trinity
  version: "1.0"
  category: development
trinity:
  requires_toolsets: [shell]
  risk: write
---

# Git workflow

Work in the repository the session's project root points at. Read before you write: `git status`
and `git log --oneline -10` first, so a commit lands on the branch the person expects.

## Committing

1. `git status --short` and `git diff --stat`: know what will go in. Never `git add -A` on a tree
   you have not listed; stage the files the task is about.
2. Write a Conventional Commits message: `type(scope): summary` on the first line, at most 72
   characters, imperative mood; a blank line; then the why, not the what, in a few lines. Types:
   `feat`, `fix`, `docs`, `test`, `refactor`, `chore`.
3. If the repository has a `.githooks` directory or a `commit-msg` hook, expect it to check the
   message and read what it says when it refuses.
4. Never commit secrets: `.env`, keys, tokens. If `git status` shows one, stop and say so.

## Branches and pull requests

- Branch from the default branch with a short, hyphenated name (`fix/receipt-order`).
- Never force-push a shared branch; never rewrite history that is tagged.
- A pull request body says what changed and why, names the tests that prove it, and links the
  issue when there is one. `references/conventional-commits.md` has the message grammar.

## When unsure

Ask before any of: `git push --force`, `git reset --hard`, `git clean`, deleting a branch, or
amending a commit that is already pushed.
