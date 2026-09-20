# ADR-0009 — Jido 2.0 for actions, directives and the effect boundary; decided by the Slice 012 design checkpoint
Status: accepted · Date: 2026-09-05 · Owner decision on the version line recorded 2026-09-20

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
