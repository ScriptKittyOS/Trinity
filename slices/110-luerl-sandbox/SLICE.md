# Slice 110: Luerl sandbox + executable skills

| Field | Value |
|---|---|
| Phase | 11 Sandbox |
| Milestone | M7 Sandboxed |
| Size | L |
| Depends on | 041 |

## Goal
In-VM sandboxed execution for agent- and user-authored scripts: Luerl runners with reduction (CPU) limits, memory
caps, time limits, no OS/IO libraries, and an explicit host API (call approved tools, read memory, emit results).
Skills may declare `trinity.lua_entry`; a `run_lua` tool executes code or a skill's script; results are structured.
Everything remains subject to the permission gate.

## Why
Skills that can execute need a real programming surface. This gives the agent one without giving it the machine.

## Scope
**In:**
- `Trinity.Sandbox` context: `run(code, opts)` → `{:ok, result, stats} | {:error, reason}`; `Trinity.Sandbox.Runner` pool under `Trinity.Sandbox.Supervisor` (poolboy or a simple DynamicSupervisor with a cap); per-run process with `max_heap_size`, reduction limit via `luerl_sandbox`, wall-clock timeout, output size cap.
- Host API exposed to Lua: `trinity.tool(name, args)` (goes through the permission gate as the calling session), `trinity.memory.recall(q, k)`, `trinity.log(msg)`, `trinity.result(table)`, `json.encode/decode`, string/table/math stdlib subsets. No `os`, `io`, `require`, `load`, `dofile`, `package`.
- `run_lua` tool (risk `:exec`, but since it is in-VM, default policy `:ask` first time then "allow for session"; configurable); skill scripts: `skill_run(name, args)` executes `scripts/<lua_entry>` with the skill's declared `requires_tools` pre-checked.
- Scanner (041) extended to Lua: flags attempts to reference forbidden globals.
- UI: sandbox runs visible in the tool-call card with stats (reductions, time, memory).
- Docs: `docs/sandbox.md`: capabilities, limits, threat model, what it does not protect against (native/shell).
**Out:** WebAssembly runtime (interesting future option), Python.

## Acceptance criteria
1. [manual] Infinite loop script → terminated by reduction limit within the configured bound; runner process gone; no VM impact (test measuring scheduler utilisation before/after).
2. [auto] Memory bomb (`t = {}; while true do t[#t+1] = string.rep("x", 1e6) end`) → killed by `max_heap_size`; app healthy (test).
3. [auto] `os.execute`, `io.open`, `require` → errors (tests).
4. [auto] Script calling `trinity.tool("fs_write", …)` triggers the permission gate; denied → Lua receives an error value; allowed → file written (tests).
5. [auto] A skill with `lua_entry` runs via `skill_run` and returns a structured table mapped to a `%Result{}` (test with a fixture skill).
6. [auto] 20 concurrent runs respect the pool cap (test with timing).
7. [manual] Manual: ask the agent to "compute the total size of all markdown files under X using a script" → it writes Lua, runs it via the sandbox, returns the answer (GIF).
8. [manual] `docs/sandbox.md` reviewed by the human.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC1**: Infinite loop script → terminated by reduction limit within the configured bound; runner process gone; no VM impact (test measuring scheduler….
- **AC7**: Manual: ask the agent to "compute the total size of all markdown files under X using a script" → it writes Lua, runs it via the sandbox, returns….
- **AC8**: `docs/sandbox.md` reviewed by the human.

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/07, docs/sandbox.md · [ ] VERSIONS (luerl/sandbox ✅) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s110): complete slice 110 (Luerl sandbox and executable skills)` · tag `slice/110`

## Risks / open questions
- Luerl performance for data-heavy scripts; measure and document (it is a sandbox, not a runtime for heavy compute: heavy work goes to approved shell tools).
