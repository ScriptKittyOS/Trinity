# Slice 033: NOTES

## Measured 2026-09-21 before any code: the cap and the context tier's budget

Slice 030 left the context tier's budget at its 300-token starting value with "nothing to measure until 040".
This slice puts `AGENTS.md` in that tier, so there is something to measure. With the tree's estimator
(`Trinity.Memory.Tokens.estimate/1`, bytes over three): this repository's own `CLAUDE.md`, the kind of file an
`AGENTS.md` is, measures 8,546 bytes and 2,849 tokens; `README.md` 8,263 bytes, 2,755 tokens; `CONTRIBUTING.md`
2,931 bytes, 977 tokens. So:

- the `AGENTS.md` cap is **16,384 bytes** across every file found on the path (`config :trinity, :agents_md,
  max_bytes:`), 5,462 tokens by the estimator: two files the size of this tree's own fit; a third is cut, and the
  cut says what went;
- the context tier's budget rises from 300 to **5,800 tokens**: the cap's 5,462 plus 300 for the skills index
  040 adds, so the cap binds first and states its cut inside the block, and the tier budget stays the backstop
  whose receipt means the estimator and the cap disagree (the same arrangement as 030's volatile tier).

## G1 plan, 2026-09-21

Tree at `294eecb` (030 approved); branch `slice/033-project-context-agents-md`; ROADMAP row 033 to
`in_progress` in this commit. Each line names its test.

1. Migration: `sessions.project_root` (string, nullable); `Sessions.set_project_root/2`; the session's tool
   context carries it as `cwd`, so the filesystem allowlist (022) and, at 040, skill discovery read the same
   setting. Test: a session with a root resolves a relative path inside it; without one, as before.
2. `Trinity.Context.AgentsMd` (`lib/trinity/context/agents_md.ex`, its own small boundary over the core):
   `discover(root, cwd)` lists every `AGENTS.md` from the root down to the working directory, outermost first;
   `load(root, cwd)` reads them, caps the total at `max_bytes` (the nearest file kept whole first, the outer
   ones cut, and the cut stated as `[cut: N bytes of <path>]`), and renders each inside
   `<untrusted source="agents_md" path=... digest=...>` with the line that the nearest file wins where they
   disagree. Fixture repositories under `test/support/fixtures/agents/` (a plain one, a nested one, a big one,
   one carrying "disable approvals"). Tests: AC1 (the content in the context tier, tagged untrusted), AC2
   (precedence and the stated cut).
3. `Prompt.build/5` takes `context:` (the tier's text: the AGENTS.md block, then the skills index when 040
   adds it) and the Session reads the files on every turn (live reload: a change is in the next turn's prompt;
   a test edits the fixture between two turns). The taint of the tier is untrusted by its block, and the
   prompt's untrusted rule already covers it.
4. AC3: a fixture whose `AGENTS.md` says approvals are disabled; a write tool call in a session rooted there
   still asks. The gate never reads the prompt, and the test proves the end to end.
5. UI: the project root as a field in the chat's bar (an input beside the model picker, saved on change); the
   FS allowlist follows it. LiveView test.
6. docs/05 (the column), docs/07 (the context tier's provenance line), docs/01's Sessions row (Context).

Manual verification queue: none; every criterion is `[auto]`.

Deviations stated before any code: (a) the context tier's budget changes from 300 to 5,800 tokens for the
measured reason above; (b) "project root(s)" is one root per session at this slice (the column is one string);
several roots is a follow-up until a slice needs it.
