<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Telemetry: the event catalogue

Slice 090. Every event Trinity emits, what it measures, and what it carries as metadata.

**This document is written before the emitters, and that order is deliberate.** An event name is an
interface: the moment something consumes `[:trinity, :llm, :call, :stop]`, renaming it breaks that
consumer silently, because a handler attached to a name that no longer fires simply never runs. So
the names are decided once, here, and the code follows the document rather than the document
recording whatever the code happened to do.

## What is never in an event

**No prompt text, no completion text, no key material, no tool arguments.** Telemetry handlers are
attached by anything in the VM and their output reaches dashboards, logs and exporters, which is
exactly the path by which a conversation ends up somewhere nobody meant it to go. Events carry
identifiers, counts and durations; the content they describe stays in the database, behind the
permission model, where a person can decide who reads it.

A tool call's event names the tool, not its arguments. An LLM call's event names the model and the
token counts, not the messages. This is a rule rather than a default: a new event that would need
content to be useful is a new event that needs rethinking.

## The conventions

All events are `[:trinity, ...]`. Anything with a duration follows `:telemetry.span/3`'s shape:
`:start`, then `:stop` **or** `:exception`, so a failed operation is never silently absent from the
count of completed ones.

Durations are in native units, as `:telemetry.span/3` emits them; convert with
`System.convert_time_unit/3` at the point of display rather than at the point of measurement.

## The events

### LLM

| Event | Measurements | Metadata |
|---|---|---|
| `[:trinity, :llm, :call, :start]` | `system_time` | `model`, `provider`, `session_id`, `kind` (`:stream`, `:generate`, `:embed`) |
| `[:trinity, :llm, :call, :stop]` | `duration`, `input_tokens`, `output_tokens`, `cost_usd` | as above, plus `finish_reason` |
| `[:trinity, :llm, :call, :exception]` | `duration` | as above, plus `kind`, `reason` |

`cost_usd` is computed from the model registry's price, the same figure written to `usage_events`,
so a dashboard total and a ledger total cannot disagree by construction.

### Tools

| Event | Measurements | Metadata |
|---|---|---|
| `[:trinity, :tool, :call, :start]` | `system_time` | `tool`, `session_id`, `risk` |
| `[:trinity, :tool, :call, :stop]` | `duration` | as above, plus `result` (`:ok` or `:error`) |
| `[:trinity, :tool, :call, :exception]` | `duration` | as above, plus `kind`, `reason` |

### Permissions

| Event | Measurements | Metadata |
|---|---|---|
| `[:trinity, :approval, :requested]` | `count: 1` | `tool`, `risk`, `session_id` |
| `[:trinity, :approval, :decided]` | `count: 1`, `waited_ms` | `tool`, `risk`, `session_id`, `decision`, `basis` |

`waited_ms` is how long a person took to answer. It is the number that says whether the permission
model is usable or merely correct.

### Sessions

| Event | Measurements | Metadata |
|---|---|---|
| `[:trinity, :session, :transition]` | `count: 1` | `session_id`, `from`, `to` |

### Gateways

| Event | Measurements | Metadata |
|---|---|---|
| `[:trinity, :gateway, :inbound]` | `count: 1` | `adapter`, `outcome` (`:placed`, `:command`, `:unpaired`, `:rate_limited`) |
| `[:trinity, :gateway, :outbound]` | `count: 1`, `bytes` | `adapter` |

`outcome` is deliberately a closed set: a counter whose label is free text becomes a cardinality
problem the first time it carries an id.

### Budgets

| Event | Measurements | Metadata |
|---|---|---|
| `[:trinity, :budget, :exceeded]` | `spent_usd`, `limit_usd` | `scope` (`:day`, `:session`, `:persona`), `scope_id` |

### `[:trinity, :tool, :surface_drift]`

Slice 029. An MCP server listed a tool whose definition differs from the baseline this machine
recorded, so the tool was held rather than registered.

| | |
|---|---|
| Measurements | `fields` (how many fields changed) |
| Metadata | `server`, `tool` (the namespaced registry name), `changed` (the field **names**) |

`changed` carries names and never values. A description is content, and the whole point of holding
the tool is that its new content has not been read by anyone who is allowed to approve it.

## Traces: a turn is a tree, without a tracing library

Every event emitted inside a turn carries `trace_id` and `parent_span_id`, and every span also
carries its own `span_id`. One turn is one trace: the model call and any tool calls beneath it
share an id and name the span that encloses them, so the activity buffer and the page can assemble
a turn into a tree with nothing installed.

Outside a trace, an event carries **no** trace id rather than an invented one. A span with an id
nothing else shares is noise wearing a tree's clothes.

**This is deliberately not OpenTelemetry**, and the reasoning is recorded in slice 090's NOTES
along with the measurement behind it. In short: the events are the durable interface and an
exporter is one consumer of them, so the linkage belongs here; and when an exporter is wanted, the
parentage it needs is already in the metadata, which makes it an export step rather than a change
to any emitter.

## Where they go

- **LiveDashboard**, through `TrinityWeb.Telemetry`'s metrics.
- **The Activity page**, through a bounded ring buffer. Bounded because an unbounded event buffer
  is a memory leak with a nice name.
- **`usage_events`**, for cost, which is written by the LLM path itself rather than by a handler:
  a handler that fails or is detached would silently stop the ledger, and a missing bill is worse
  than a missing chart.

## Adding an event

Add it to this table first, then emit it. If it needs content to be useful, it is the wrong event.
