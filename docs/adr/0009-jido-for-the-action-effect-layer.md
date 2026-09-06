# ADR-0009 — Jido 2.0 for actions, directives and the effect boundary; decided by the Slice 012 design checkpoint
Status: proposed · Date: 2026-09-05

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
