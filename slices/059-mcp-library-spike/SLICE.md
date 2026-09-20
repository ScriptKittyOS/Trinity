# Slice 059: MCP capability gap against beam_mcp, and the server seam probe

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5a Automates |
| Size | S/M |
| Depends on | 020 |

Supersedes the 2026-09-05 draft, which was a library selection spike. ADR-0007 decision 5 (owner decision
2026-09-08, recorded 2026-09-20) names beam_mcp the server core; this slice measures, it does not choose.

## Goal
`FINDINGS.md` with one row per item of the 2026-07-28 checklist, each row stating what beam_mcp 0.8.0 ships,
carries but Trinity does not yet read, refuses on its will-not-implement page, or leaves open, with a path and
line at the pinned commit; the two conflicts between that page and Trinity's own slices stated against the slice
lines they collide with; a probe, on a throwaway branch of beam_mcp that is never merged, of whether
`BeamMCP.Transport.HTTP` can take a `:server` module option without a fork; and `beam_mcp` added to the tree as a
dependency behind the `Trinity.MCP` boundary.

## Why
Slices 060 to 062 are written against what the core does. A gap discovered mid-build is a scope change; a gap
in a table is a plan. The seam probe turns a question to another project into a diff size.

## Checklist (one FINDINGS row each)
1. Revision negotiation: `server/discover` for 2026-07-28, `initialize` for 2025-11-25, from one route.
2. Stateless Streamable HTTP as a Plug; `Mcp-Method` and `Mcp-Name` headers; no session identifier.
3. stdio transport.
4. tools: `tools/list`, `tools/call`, deterministic order, schema validation.
5. resources: `resources/list`, `resources/read`, templates, subscriptions.
6. prompts: `prompts/list`, `prompts/get`.
7. `ttlMs` and `cacheScope` on every cacheable result.
8. `resultType` on every result, including `server/discover`.
9. MRTR: `input_required`, `requestState`, `inputResponses`.
10. Tasks extension.
11. OAuth resource server hooks: what the `:authorize` and `:authorize_body` hooks give a host and what they do
    not.
12. Client role.
13. `connectome://` resources and the `:observe` tool: shipped by the core; whether Trinity exports them is a
    061 G1 decision, default off.
14. Telemetry events the core emits around dispatch, by name and metadata shape, for slice 090's catalogue.
15. The signer seam: `BeamMCP.Signer`, `Canonical.signature/3`, and whether a verifier of exported bytes can
    read the signature algorithm without the signer module.

## Scope
**In:**
- The FINDINGS table, every cell derived from `docs/will-not-implement.md`, `docs/public-api.txt`, the README
  and the source of beam_mcp at the pinned commit, with the deriving command pasted.
- The seam probe: a throwaway branch on a local clone of beam_mcp adding the `:server` option; the diff size in
  lines; which of its census tests change; pasted output. The branch is deleted at the end of the slice.
- `{:beam_mcp, "~> 0.8"}` in `mix.exs`; the `VERSIONS.md` row flipped by `mix versions.gen`; a `Trinity.MCP`
  boundary declared with `BeamMCP` as its only permitted external, so nothing else in Trinity can import it.
- A proposed amendment to ADR-0007 if any finding changes the shape of 060 to 062.
**Out:**
- Building anything on the core: that is 060 and 061.
- Any change to beam_mcp itself. A change it needs is a question to that project's board, routed through the
  owner, never a patch from here.

## Deliverables
- `slices/059-mcp-library-spike/FINDINGS.md`, the pasted probe output in `PROOF.md`, the dependency and the
  boundary in `mix.exs` and `lib/trinity/mcp/`, the `VERSIONS.md` row.

## Acceptance criteria
1. [auto] `FINDINGS.md` carries one row per checklist item, each with a path and line at the pinned beam_mcp
   commit and the command that derived it.
2. [auto] The two conflicts are stated against slice lines: will-not-implement entry 12 (no MRTR) against 061's
   `input_required` criteria; entries 9 (no client) and 8 (no OAuth) against 060 and 062.
3. [auto] The seam probe reports the diff size and the census tests it touches, with output; no code from it is
   merged anywhere.
4. [auto] `beam_mcp` is in `mix.lock`, its `VERSIONS.md` row reads in `mix.lock`, and `mix compile
   --warnings-as-errors` fails on a planted `BeamMCP` import outside `Trinity.MCP` (test).
5. [auto] Gate green; coverage line reported.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result. A sentence is not
  proof.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–5 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s059): complete slice 059 (MCP capability gap and seam probe)` · tag `slice/059`

## Risks / open questions
- The seam is another project's decision. If it is refused, 061 takes the recorded fallback in ADR-0007
  decision 6.
