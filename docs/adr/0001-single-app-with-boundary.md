# ADR-0001 — Single Mix app with `boundary`, not an umbrella
Status: accepted · Date: 2026-09-05

## Context
We need modularity strong enough that adding a tool, provider, or gateway never touches core code, and that
context dependencies cannot silently rot. Options: umbrella project, poncho, single app with conventions,
single app with `boundary`.

## Decision
One Phoenix app, `Trinity` + `TrinityWeb` namespaces, contexts as `boundary` modules with explicit `deps:` and
`exports:`. Pluggable concerns are behaviours registered via config lists and a `Registry`.

## Consequences
- Boundary violations fail the gate at compile time.
- No umbrella build/config overhead; one release.
- If we ever need separate deployables (e.g. a headless server), the contexts are already isolated enough to extract.
