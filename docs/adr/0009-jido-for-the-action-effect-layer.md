# ADR-0009 — Jido 2.0 for actions, directives and the effect boundary; decided by the Slice 012 design checkpoint
Status: superseded by the decision appended 2026-09-20 (no Jido) · Date: 2026-09-05

## Context
ADR/tech-stack v1 said "Jido not chosen". Reconsidered: Jido has a worked vocabulary for actions, directives and
the effect boundary, which is the same split Trinity needs at `Trinity.Effects`. Building a parallel vocabulary
for it is worth doing only if Jido's does not fit.

## Decision (provisional)
Adopt Jido 2.0 for the **action / directive / effect** layer: tools are `Jido.Action`s with schemas; effects are
runtime-owned directives that cross one boundary (`Trinity.Effects`, the membrane); the Session remains an
OTP `gen_statem` owning the turn loop and may or may not be a `Jido.Agent`. The Slice 012 design checkpoint
(G1 plan) measures: (a) can the M3/M4 properties be asserted as tests against Jido's structures; (b) does
`Jido.Agent` add anything the gen_statem does not; (c) dependency weight in the desktop binary. The checkpoint
returns one of: full adoption, actions/directives only, or reject with measured reasons; this ADR is then
finalised.

## Consequences
- Slice 020's tool behaviour becomes a thin wrapper over `Jido.Action` if adopted; the registry rules (compile-time
  catalog, runtime tools cannot enter it) are unchanged.
- VERSIONS.md gains a `jido ~> 2.0` row pending the checkpoint.

## Decision, appended 2026-09-20

Owner decision, before 2026-09-19, recorded here on 2026-09-20: **the runtime is Jido v2**, pinned `~> 2.3`
(2.3.3 on hex.pm as of this record; the v3 line is at 3.0.0-beta.1, 2026-09-14, and defers live code migration
and distributed control-plane claims by its own release notes). The provisional decision above is confirmed on
the version question and on the shape: actions, directives and the effect boundary use Jido's vocabulary; the
Session stays an OTP `gen_statem`; the compile-time effect catalog and the rule that runtime tools never enter it
are unchanged whichever way `Jido.Agent` lands. The Slice 012 design checkpoint still measures (a), (b) and (c)
as written and reports; what it can no longer return is "reject", because the runtime question is decided. It
may still return "actions and directives only".

One consequence for the standards register rather than for a slice: another system in the same platform family
runs on the same Jido line. That is a shared library, not a shared runtime, and it is not on the path a finding
takes; the register carries the row and the argument, and no slice here does.

## Decision, appended 2026-09-20 (later): no Jido at all

The Slice 012 checkpoint ran on 2026-09-20 against `jido` 2.3.3, `jido_action` 2.3.2 and `jido_signal` 2.2.0,
read from their Hex tarballs (the measurements and the commands are in `slices/012-*/NOTES.md`). Its findings:
(a) M4 is assertable against `Jido.Action` and M3 only with a census, because `Jido.Exec.run/4` takes caps as
call-site options; (b) `Jido.Agent` adds sensors, a scheduler, signal routing and worker pools the plan assigns
elsewhere, and an `AgentServer` that executes tools through `Jido.Exec`, a second path beside
`Trinity.Effects`; (c) `jido` is 29,820 lines with ten runtime dependencies, `jido_action` six. The one piece
with value, `Jido.Action` as the shape a tool is written in, is a few dozen lines to write and the tree already
carries `jsv` for JSON Schema validation through req_llm.

**Owner decision, 2026-09-20, on those measurements: Trinity uses no Jido package.** This supersedes the
provisional decision above and the earlier appended line recording "the runtime is Jido v2"; that line stands
as written and this one is its correction. Consequences: slice 020 writes `Trinity.Tools.Tool` as Trinity's own
behaviour (a module with a name, a JSON Schema for its parameters validated with `jsv`, `execute/2`, and the
effect and risk declarations the security model needs), around the permission gate and the effect catalog
rather than around a library's executor; the `jido` row leaves VERSIONS.md; the standards register's row on a
shared library with a sister system is closed as not applicable; nothing in slice 012 changes, because it
used none of it.
