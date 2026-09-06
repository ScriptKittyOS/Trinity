# ADR-0010 — Authority is selected once, at boot
Status: accepted · Date: 2026-09-05

## Context
`Trinity.Authority` has one in-tree implementation and admits external adapters (ADR-0008). Which one is in force
has to be unambiguous, visible after the fact, and impossible to change while the system is running. An agent that
can alter its own authority at runtime does not have any.

## Decision
- `TRINITY_AUTHORITY` selects the implementation. `local` is the default and what most installations run.
- Any other value is read as a module name. Trinity **refuses to start** unless that module is loaded and
  implements every callback of the behaviour, and the refusal names which condition failed.
- The selection is read once at boot, recorded in the boot receipt, and cannot be changed afterwards by any tool,
  skill or session. No configuration reload path reaches it.
- Under `local`, no adapter module is loaded and no outbound connection is attempted on its behalf. Asserted by a
  test rather than by reading the code.

## Consequences
- A misconfigured deployment fails loudly at boot instead of running quietly with weaker authority than intended.
  That silent case is the one worth designing against; the loud one is merely inconvenient.
- The boot receipt makes the selection auditable later, by someone who was not there.
- Slice 024 builds the selection, the refusal and the boot receipt.
