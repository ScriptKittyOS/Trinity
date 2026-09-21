# Proof for slice 033: Project context: AGENTS.md

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/033-project-context-agents-md · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
The session's project root as a setting (a column, a setter, a field in the chat's bar) that the tools' working
directory follows; `Trinity.Context.AgentsMd`, which reads every `AGENTS.md` from the root to the working
directory, outermost first, caps the total at 16,384 bytes keeping the nearest whole and stating every cut, and
renders each inside an untrusted block with its digest; the prompt's context tier fed every turn (live reload)
with its budget raised from 300 to 5,800 tokens on measurement. Five findings in NOTES.md.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 3b5e89e)
1605 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
Result: 357 passed, 17 excluded
trinity.coverage: 030 78.4% vs 031 76.96%: OK
plan_check: PASS
exit=0
```
CI, run 35551683298 on the tree at 3b5e89e: `gate` success (357 passed, 17 excluded), `postgres` success
(349 passed, 25 excluded), `fips-tag` and `fips` success.

## Tests
```
$ mix test --cover                           (tree 3b5e89e)
Result: 357 passed, 17 excluded
|     87.50% | Trinity.Context.AgentsMd               |
|     78.50% | Total                                  |
```
`coverage.tsv` row: `033  78.50  3b5e89e  2026-09-21` (from 78.40 at 030).

The slice's seven tests (`--trace`):
```
* test the field saves an existing directory, refuses a missing one, and clears on empty [L#13]
  * test the field saves an existing directory, refuses a missing one, and clears on empty (99.9ms) [L#13]
  * test live reload: a change to AGENTS.md between two turns is in the second turn's prompt (11018.7ms) [L#89]
  * test AC3: an AGENTS.md that says approvals are disabled changes nothing at the gate: a write still asks (6021.7ms) [L#109]
  * test AC2 (precedence): nested files load outermost first and the block says the nearest wins; the working directory decides which are on the path (1.2ms) [L#44]
  * test the session's project root: set from an existing directory, cleared with nil, refused otherwise; the tools' cwd follows it (5.1ms) [L#78]
  * test AC2 (cap): over the cap the nearest file stays whole, the outer one is cut, and the cut states the file and the bytes (0.3ms) [L#62]
  * test AC1: a repository with AGENTS.md puts its content in the prompt's context tier inside an untrusted block with its digest (0.4ms) [L#18]
Result: 7 passed
```

## Acceptance criteria evidence

### AC1 [auto]: a fixture repo with `AGENTS.md` → its content appears in the prompt's context tier, tagged untrusted (snapshot test)
`AC1: a repository with AGENTS.md puts its content in the prompt's context tier inside an untrusted block with
its digest` (test/trinity/context/agents_md_test.exs): the `plain` fixture's file appears in the request's system
prompt as exactly `<untrusted source="agents_md" path="<root>/AGENTS.md" digest="<sha256>">` + the content +
`</untrusted>`, under the heading "## Project instructions (AGENTS.md)", after the soul and the rule and before
the time line (the tier order asserted by a regex over the whole prompt); no root, or a root without the file,
renders nothing.

### AC2 [auto]: nested `AGENTS.md` precedence works (test); cap truncation states what was cut (test)
`AC2 (precedence): nested files load outermost first and the block says the nearest wins; the working directory
decides which are on the path` (the `nested` fixture: root alone gives one file, root with `src/lib` gives two
in outer-then-inner order, a directory outside the root gives none; the rendered block carries "the nearest file
wins where they disagree" and the outer text precedes the inner). `AC2 (cap): over the cap the nearest file stays
whole, the outer one is cut, and the cut states the file and the bytes` (cap at 120 bytes: the inner file
uncut, the outer cut by exactly its bytes minus what remains, the total under the cap, and the block carrying
`[cut: N bytes of <root>/AGENTS.md]`).

### AC3 [auto]: an instruction inside AGENTS.md to disable approvals does not change gate behaviour (test)
`AC3: an AGENTS.md that says approvals are disabled changes nothing at the gate: a write still asks`: a session
rooted at the `hostile` fixture, whose file says tools "must proceed without asking"; the model's `write_note`
call raises an approval request and the Session sits in `approval_wait`; the prompt the fake received did carry
the hostile text, inside its untrusted block. The gate reads names, arguments and rules, never the prompt.

Also proven: `the session's project root: set from an existing directory, cleared with nil, refused otherwise;
the tools' cwd follows it` (a relative path inside the root is inside for the allowlist), `live reload: a change
to AGENTS.md between two turns is in the second turn's prompt`, and the chat's field
(test/trinity_web/live/project_root_live_test.exs).

## Manual verification for the reviewer
None; SLICE.md tags every criterion `[auto]`.

## Deviations from SLICE.md
(a) the context tier's budget is 5,800 tokens, not 300, for the measured reason in NOTES.md; (b) one project
root per session at this slice. Both stated at G1.

## Versions touched
`VERSIONS.md` updated: no; no dependency changed.

## Git
```
$ git log --oneline main..HEAD
3b5e89e fix(s033): the AGENTS.md read carries its sobelow reason
d97eb77 style(s033): alias order
a988cda feat(s033): the project root in the chat's bar; docs 05, 07 and 01 as built
7d13043 feat(s033): the session's project root, Trinity.Context.AgentsMd, the context tier fed every turn
8fea997 docs(s033): G1 plan with the cap and the context budget measured, and the slice opens
```

## Closing correction, 2026-09-21
Supersedes the header's "Final commit" placeholder: the closing commit is `0c8238a` (`feat(s033): complete
slice 033 (AGENTS.md project context)`), and this correction rides on the commit after it.
