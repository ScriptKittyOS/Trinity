# Slice 059: NOTES

## G1 plan, 2026-09-21

Tree at `76b72ce` on `main` (040 and 041 approved, M4 reached); branch `slice/059-mcp-gap`; ROADMAP row
059 to `in_progress`. The slice measures, it does not build (SLICE.md, superseding the 2026-09-05 draft).

1. A clone of beam_mcp at `v0.8.0` (its commit `cfa706b`, the one ADR-0007 decision 5 names) on its own
   pinned toolchain (Erlang 28.1.1, Elixir 1.18.4-otp-28, both installed here beside Trinity's), its suite
   run once as the baseline. FINDINGS.md: one row per checklist item, each cell from `docs/will-not-implement.md`,
   `docs/public-api.txt`, the README and the source at that commit, with the deriving command. Test AC1
   (`test/trinity/mcp/findings_test.exs`: fifteen rows, each with a path and line and a command).
2. The two conflicts against the slice lines (entry 12 against 061's `input_required` criteria; entries 9 and 8
   against 060 and 062), in FINDINGS. Test AC2.
3. The seam probe on a throwaway branch of the clone: the `:server` option on `BeamMCP.Transport.HTTP`; the
   diff size and the census tests that move, the output pasted; the branch deleted. Test AC3 (the report,
   and no beam_mcp code in this tree).
4. `{:beam_mcp, "~> 0.8"}` in mix.exs; the VERSIONS row flipped by `mix versions.gen`; `Trinity.MCP` as the
   boundary that alone may reach `BeamMCP.*`, with the boundary compiler checking every call into the
   `beam_mcp` application (`boundary: [default: [check: [apps: [:beam_mcp]]]]`). Test AC4 (the lock, the row,
   the configuration, the source census; the planted reference's refusal pasted from the compiler).
5. Gate and coverage (AC5); docs/01 (the boundary as built); an ADR-0007 amendment only if a finding changes
   060 to 062's shape.

Manual verification queue: none (every criterion is `[auto]`).

Deviation stated before code: AC4 says "(test)" for the planted reference's refusal; a test cannot run the
project's own compiler over a planted file without changing the tree it runs in, so the refusal is pasted from
the command in PROOF.md, and the test holds what makes it (the global check, the one boundary, the census that
no `BeamMCP.` reference exists under `lib/` outside `lib/trinity/mcp.ex`) and that the plant is real.

## Findings at G3, 2026-09-21

1. **`Trinity.MCP` is a top-level boundary.** The boundary library lets a nested boundary depend on an
   external module only when an ancestor does, and `Trinity` must never list `BeamMCP` (that would open the
   core to it); so `Trinity.MCP` is `top_level?: true` with `deps: [Trinity, BeamMCP.JSON]`, as `Trinity.Smoke`
   is. beam_mcp defines no boundaries and has no `BeamMCP` root module, so each of its modules Trinity reaches
   is named as its own implicit boundary in that list; 060 and 061 extend it as they reach more of the core.
   docs/01's table kept its row; the note says how it is placed.
2. **The seam is five lines and one pinned list.** The probe's diff is three insertions and two deletions in
   `lib/beam_mcp/transport/http.ex`; the one census that moves is `no_catalog_test.exs` "the catalog is called
   through three callees…", which pins every call through a runtime module with parentheses and would gain
   `handle_message/2` and `new/1` on `BeamMCP.Transport.HTTP.do_dispatch/3`. Whole suite on the probe: 705
   tests, that one failure. The ask to beam_mcp's board, through the owner, is those five lines and two
   entries; nothing was pushed, the branch is gone.
3. **`tools/list` keeps the catalog's order.** Resources, templates and prompts are sorted by the core;
   tools are not (`catalog.ex:150`). Deterministic order is the host's, so 061's catalog sorts. Recorded for
   061's G1 rather than raised with the core: the core's choice is defensible (a host may want its order).
4. **The Tasks extension is open in the core**, neither built nor on the will-not-implement page; 060 builds
   no client for it and 061 does not advertise it. If a later slice needs it, the question goes to beam_mcp's
   board first.
5. **No ADR-0007 amendment.** Nothing measured changes decisions 5 to 8; the two new facts (3 and 4) are
   inputs to 060 and 061's G1 plans, recorded in FINDINGS' last section.
6. **The core on Trinity's toolchain.** The clone's suite ran on beam_mcp's pinned toolchain (its
   `.tool-versions`, installed here). Trinity compiles the package on 1.20.4-otp-28 / 28.5.0.5 (`mix compile
   --warnings-as-errors` clean, the 25 files); the census that pins "eight atoms exact for the OTP the gate
   runs" is beam_mcp's own gate's concern, not a consumer's.

## Follow-ups

- The seam request to beam_mcp's board (finding 2), routed through the owner; 061 is blocked on it (its
  SLICE.md says so) and has the ADR's fallback.
- `Trinity.MCP.core_events/0` into slice 090's telemetry catalogue.
