# Slice 090 — Observability: telemetry, cost ledger, LiveDashboard

| Field | Value |
|---|---|
| Phase | 9 Ops |
| Milestone | M6 Ships |
| Size | M |
| Depends on | 011 |

## Goal
Every LLM call, tool call, approval, gateway event, and session transition emits Telemetry; a cost ledger and
budgets (per session/persona/day) with alerts; LiveDashboard with custom metrics; an in-app "Activity" page;
structured logs with redaction; optional OpenTelemetry export.

## Scope
**In:**
- `Trinity.Telemetry` events catalogue documented in `docs/telemetry.md`; `:telemetry` handlers → `usage_events`, metrics (Telemetry.Metrics), and a ring buffer for the Activity page.
- Cost ledger: `Trinity.Telemetry.Costs` — totals by day/session/persona/model from `usage_events`; budgets in settings; when exceeded: warn in UI, optionally block new turns (setting).
- LiveDashboard mounted (dev always; prod behind setting) with custom pages: sessions (pids, state, memory), tools latency, LLM latency/tokens.
- Activity page: recent events stream, filter by session/type.
- Log redaction: a `Logger` filter that masks API keys and truncates prompts at `:info`.
- OpenTelemetry (`opentelemetry`, `opentelemetry_phoenix`, `opentelemetry_ecto`) wired with OTLP exporter disabled by default; a span per turn with child spans per LLM/tool call.
**Out:** Prometheus endpoint (trivial follow-up), external APM.

## Acceptance criteria
1. [auto] Telemetry test: a turn with one tool call emits the documented events in order with expected metadata (`:telemetry_test`).
2. [manual] Cost totals match the sum of `usage_events` for a seeded dataset; budget exceeded triggers the warning event and, when set, blocks a new turn with a clear UI message (tests + screenshot).
3. [manual] LiveDashboard custom page lists live sessions with their gen_statem state (screenshot).
4. [auto] Logger redaction test: an API key in a log message is masked.
5. [auto] OpenTelemetry: with the exporter set to a local collector (or in-memory exporter in test), one turn yields a trace with nested spans (test).
6. [manual] Activity page screenshot.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2** — Cost totals match the sum of `usage_events` for a seeded dataset; budget exceeded triggers the warning event and, when set, blocks a new turn with….
- **AC3** — LiveDashboard custom page lists live sessions with their gen_statem state (screenshot).
- **AC6** — Activity page screenshot.

## Definition of Done
- [ ] gate green · [ ] AC1–6 proven · [ ] docs/telemetry.md · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s090): complete slice 090 — observability and cost ledger` · tag `slice/090`
