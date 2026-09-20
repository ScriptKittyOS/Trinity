# Slice 011: NOTES

## G1 plan, 2026-09-20

Tree at `6af7ee6` on `main` (010 approved); branch `slice/011-llm-provider-layer`; ROADMAP row 011 set to
`in_progress` in this commit. req_llm 1.24.0 was read from its Hex tarball before this plan was written (public
entry points `generate_text/3`, `stream_text/3`, `generate_object/4`, `embed/3`; stream chunk types `:content`,
`:thinking`, `:tool_call`, `:meta`; usage keys `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`,
`reasoning_tokens`, `total_cost`; model spec `"provider:model"`; keys from a per-request `:api_key` option, the
`:req_llm` application env, or the provider's env var). Each line names its test; the order is the build order.

1. Dependencies: `req_llm` at 1.24.0 inside the `~> 1.22` pin, `mox` for tests. What enters `mix.lock` with
   req_llm is counted and its licences listed in NOTES.md, because the desktop binary carries it. VERSIONS rows
   flipped by `mix versions.gen`. Test: `mix hex.audit` and `mix deps.audit` green; `versions.verify` OK.
2. `Trinity.LLM.Event`: the seven event shapes from SLICE.md as a typespec plus `valid?/1`, the single source of
   truth 012 and 013 consume. `Trinity.LLM.Request` struct (system, messages, tools, model, params) with a
   changeset-free `new/1` that validates roles and tool schemas. Tests: every shape accepted, a foreign shape
   refused.
3. `Trinity.LLM.Provider` behaviour: `stream/3`, `generate/2`, `generate_object/3`, `embed/2`, `models/0`,
   `capabilities/1`. `Trinity.LLM.Registry` from `config :trinity, :llm` (models as `{id, provider, model, caps,
   price}`, `default_model`), `models/0`, `default_model/0`, `lookup/1`. Test: a registry entry resolves to its
   provider module; an unknown id is refused by name.
4. `Trinity.LLM` public API, resolving the provider from the registry entry for the request's model; `stream/3`
   (function) and `stream_to/3` (pid, events as messages); `Trinity.LLM.ProviderMock` (Mox) as the test provider
   for the registry's `fake` provider. Boundary `Trinity.LLM` with `deps: [Trinity]`, exporting the API,
   `Request` and `Event`. Test (AC7): switching `default_model` in config changes the provider used, no code
   change.
5. `Trinity.LLM.Providers.Fake` in `test/support`: streams a scripted response (deltas, one tool call in three
   chunks, usage, done), scriptable to raise transient or non-transient errors N times. Test (AC1): the full
   event sequence, in order.
6. `Trinity.LLM.Providers.ReqLLM`: `Request` to req_llm messages and `ReqLLM.Tool`; `stream_text` chunks to
   events with tool calls assembled (start on the first chunk naming a call, deltas while arguments grow, end
   when the call is complete or the stream ends); `:meta` to `{:usage, _}` and `{:done, reason}`; `generate`,
   `generate_object` (req_llm's JSON schema path), `embed`. Provider mapping for `anthropic`, `openai`,
   `openrouter`, `google`, `openai_compatible` (the openai provider with `base_url` and a per-request key).
   Errors classified: timeouts, 429, 5xx, connection refused are transient; 4xx otherwise are not. Unit tests
   over recorded chunk sequences; live tests in line 9.
7. `Trinity.LLM.Retry`: attempts and base backoff from config; transient errors retried, non-transient returned
   at once; optional fallback model list tried in order after the attempts. Test (AC4): the fake raises a
   transient error twice then succeeds; raises N+1 times then `{:error, _}`; a non-transient error returns
   immediately with one attempt.
8. `usage_events` migration and `Trinity.LLM.Usage`: one row per completed call with model, provider, tokens,
   and cost computed from the registry price; req_llm's own `total_cost` kept in `provider_meta` and never
   used. Test (AC5): a row exists after a fake call with the expected cost; the Postgres job applies the
   migration.
9. Live tests, `@tag :live`, excluded by default (NetworkGuard's opt-in path): OpenRouter with
   `TRINITY_LIVE_MODEL` and NVIDIA through `openai_compatible` with `NEMOTRON_BASE_URL`, `NEMOTRON_MODEL` and the
   key as `:api_key`; a preflight that the model id is on `GET /models` and names a 410 as end of life. Cases:
   a streamed completion with deltas and done; a tool call; `generate_object` against a schema (AC2);
   `embed` against `nvidia/nemotron-3-embed-1b` with the declared dimension (AC3). Output pasted, keys
   redacted (AC6).
10. `Trinity.Config.secret/1`: environment now, keychain at slice 100; the adapter reads keys only through it.
    Test: a missing key is a named error, not a nil passed to the provider.
11. Anthropic prompt-cache hint: a `cache: true` param maps to req_llm's cache-control option for the anthropic
    provider and is dropped for others. Unit test on the mapping; not measured live (no Anthropic key here).
12. Gate, coverage row, PROOF.md, ROADMAP to `done`, through a pull request; tag `slice/011` after the merge.

Manual verification queue, as SLICE.md tags them: AC2 (live `generate_object`) and AC6 (`mix test --only live`,
output pasted with keys redacted). Both run on this machine with the owner's keys in `.env`; the owner reads
the pasted output at G4. The developer machine, the model ids and the probe outputs behind the choice:

- OpenRouter, `inclusionai/ling-3.0-flash-vl:free` (owner's pick): tool call `get_weather` with
  `{"city": "Paris"}`, 298 tokens, served by Novita; streamed completion 59 chunks.
- NVIDIA endpoint, `nvidia/nemotron-3.5-lightning-30b-a3b`: tool call, 317 tokens; streamed completion 20
  chunks. The id first set, `nvidia/llama-3.3-nemotron-super-49b-v1.5`, answered `410 Gone` (end of life
  2026-08-26); that is why line 9 carries a preflight.

Deviations from SLICE.md, stated before building: the five provider mappings are written; only OpenRouter and
the NVIDIA endpoint are measured live, and PROOF.md says so per provider. `Trinity.LLM.Supervisor` from docs/01
(rate limiters) is not built here: nothing in this slice needs a process, and a supervisor with no children
would be a claim; 012 adds it when the Session needs one. Recorded as a follow-up.

## Line 1, 2026-09-20: the dependencies, counted

`req_llm ~> 1.22` resolved to 1.24.0 and `mox ~> 1.2` to 1.3.1. `mix.lock` went from 68 to 80 packages. The
twelve that entered, with licence from hex.pm metadata (`curl -s https://hex.pm/api/packages/<name> | jq
.meta.licenses`):

| package | version | licence | why req_llm needs it |
|---|---|---|---|
| req_llm | 1.24.0 | Apache-2.0 | the provider layer |
| llm_db | 2026.9.4 | Apache-2.0 | its model and price database, dated |
| dotenvy | 1.2.1 | Apache-2.0 | reads `.env` for provider keys |
| jsv | 0.23.0 | Apache-2.0 | JSON schema validation for structured output |
| zoi | 0.18.7 | Apache-2.0 | its struct schemas |
| splode | 0.3.2 | MIT | its error classes |
| server_sent_events | 1.1.0 | MIT | SSE parsing for streaming |
| websockex | 0.5.1 | MIT | a realtime transport Trinity does not use |
| texture | 1.2.1 | Apache-2.0 | transitive |
| toml | 0.7.0 | Apache-2.0 | transitive |
| abnf_parsec | 2.1.0 | MIT | transitive (idna) |
| idna | 7.1.0 | MIT | transitive |

Plus `mox` 1.3.1 (Apache-2.0), test only. Every licence is Apache-2.0 or MIT. `mix hex.audit`: no retired or
advisory packages. `mix deps.audit`: no vulnerabilities. `versions.verify`: OK, 80 locked, 46 pins. Binary size
delta is measured at the next package run, not estimated here.

One thing to know about `dotenvy`: req_llm's key lookup reads `.env` through it at startup. Trinity's `.env` is
gitignored and holds the owner's keys, so in the default test run the keys may be present in the environment
while the network guard still refuses every connection; the live tag is what opens the network, not the
presence of a key. Line 10 routes every key through `Trinity.Config.secret/1` anyway.

## Lines 2 to 11, 2026-09-20: what was built, and what the live suite found

**Built.** `Trinity.LLM.Event` (seven shapes, `valid?/1`); `Trinity.LLM.Request` (`new/1`, `new!/1`, roles and
tools validated); `Trinity.LLM.Error` (`transient?`, `status`); `Trinity.LLM.Provider` behaviour;
`Trinity.LLM.Registry` over `config :trinity, :llm` (read at call time, which is what makes AC7 a test);
`Trinity.LLM` (`stream/3`, `stream_to/3` under `Trinity.LLM.TaskSupervisor`, `generate/2`, `generate_object/3`,
`embed/2`, `models/0`, `default_model/0`, `capabilities/1`); `Trinity.LLM.Retry` (attempts, base backoff, no
jitter, stated); `Trinity.LLM.Usage` and the `usage_events` migration; `Trinity.Config.secret/1`;
`Trinity.LLM.Providers.ReqLLM` (the half that talks) and `Trinity.LLM.Providers.ReqLLM.Mapping` (the pure half:
chunks to events, responses to results, errors to `Error`); `Trinity.LLM.Providers.Fake` in test/support; the
Mox mock; `config/llm.exs` as the registry's own file. The registry's model strings are `"<provider>:<model>"`
split on the first colon; the provider name is one of the five the spec names, mapped to req_llm's atom
through a fixed map, so a name from config never mints an atom (sobelow found the first version doing so).

**The live suite found four defects, each fixed with its reason left in the code.**

1. `Trinity.LLM.provider_opts/2` merged the caller's opts over the entry's, so `embed(texts, model:
   "nvidia:embed")` handed req_llm a provider named `nvidia`. Entry keys now win.
2. req_llm's streaming `receive_timeout` defaults to 30 s; the NVIDIA reasoning model exceeded it before its
   first byte under load. The adapter passes `receive_timeout_ms` from config, 120 000 by default; the embedding
   call validates a different option set (no `receive_timeout`), so the budget travels as `total_timeout` there.
3. An upstream `429` from OpenRouter's free pool arrived inside a `ReqLLM.Error.API.Stream` whose own `status`
   was nil, and the first classifier called it permanent. `classify/1` now reads the innermost error that
   carries a status, a `retryable` flag or a timeout cause. Pinned by `mapping_test.exs`.
4. An inline model spec without capabilities is refused for embeddings by req_llm ("does not support embedding
   operations"); the spec now carries `capabilities: %{embeddings: true}` for a registry entry with `:embed`.

**Model ids.** req_llm's catalog does not know the free OpenRouter id or the NVIDIA ids and warned about
"unverified" models; the adapter uses an inline spec (`%{provider:, id:, capabilities:}`) because Trinity's
registry is the catalog. The NVIDIA embedding model answers with dimension **2048**.

**The tool-call assembly** follows req_llm 1.24.0's default decoder: a `:tool_call` chunk with `id`, `index` and
`expects_arg_fragments` opens a call; `:meta` chunks carry `tool_call_args` fragments by index; the finish
reason closes every open call. Reproduced with the library's own `ReqLLM.StreamChunk` constructors in
`mapping_test.exs` (13 tests), so a change in that shape is a red here first.

**Live suite, this machine, 2026-09-20** (`TRINITY_LIVE=1 mix test --only live`, keys from `.env`, redacted;
OpenRouter `inclusionai/ling-3.0-flash-vl:free` served by Novita; NVIDIA `nvidia/nemotron-3.5-lightning-30b-a3b`
and `nvidia/nemotron-3-embed-1b` at `integrate.api.nvidia.com/v1`):

```
* test nvidia:nemotron preflight: the configured model is on the provider's list [L#56]  * test nvidia:nemotron preflight: the configured m
* test nvidia:nemotron a streamed completion yields text deltas, usage and done [L#62]  * test nvidia:nemotron a streamed completion yields
* test openrouter:ling preflight: the configured model is on the provider's list [L#56]  * test openrouter:ling preflight: the configured m
* test nvidia:nemotron generate_object returns a map that validates against the schema (AC2) [L#121]  * test nvidia:nemotron generate_objec
* test openrouter:ling a tool call arrives as start, end, and a done of tool_calls [L#85]  * test openrouter:ling a tool call arrives as st
live embed: dimension 2048
* test embed returns vectors of the declared dimension against the NVIDIA embedding model (AC3) (467.4ms) [L#148]
* test openrouter:ling a streamed completion yields text deltas, usage and done [L#62]  * test openrouter:ling a streamed completion yields
* test nvidia:nemotron a tool call arrives as start, end, and a done of tool_calls [L#85]  * test nvidia:nemotron a tool call arrives as st
* test openrouter:ling generate_object returns a map that validates against the schema (AC2) [L#121]  * test openrouter:ling generate_objec
live usage row: 25 in, 14 out, provider_cost nil
* test a live call writes one usage_events row with the tokens the provider reported (740.8ms) [L#160]
Finished in 150.6 seconds (0.1s async, 150.5s sync)
Result: 10 passed, 138 excluded
```

An earlier run took 219.8 s and passed 10 of 10 as well; a run before the fixes above passed 6 of 10 and then
8 of 10, which is the record of finding them. OpenRouter's free pool returned `429` several times during these
runs; req_llm retries a 429 three times on its own and Trinity's retry sits above that.

**Coverage** 51.57% (up 6.69 from 010). `Trinity.LLM.Providers.ReqLLM` itself reads 0% in the default run: it
is the half that talks, and only the live suite reaches it; `Mapping` reads 86%.

```
$ mix gate                        → exit 0; 138 passed, 10 excluded; plan_check: PASS
$ mix test --only live            → 10 passed (above)
$ mix trinity.coverage            → 011 51.57% vs 010 44.88%: OK
```

**Deviations from SLICE.md, in addition to the two stated at G1.** The `usage_events` columns are
`input_tokens`/`output_tokens` (the Event usage keys) rather than `prompt_tokens`/`completion_tokens`, and there is
no `latency_ms` column: latency is a Telemetry measurement at 090; docs/05 now says both. `models/0` on the
req_llm provider returns `[]`: req_llm's catalog is not Trinity's registry and listing it would be a claim
about models Trinity has not configured. `capabilities/1` on the adapter is the fixed `[:stream, :tools,
:json]`; the registry entry is the source callers use.

## Follow-ups
- `Trinity.LLM.Supervisor` (docs/01, rate limiters): when 012's Session needs a process. Only the task
  supervisor for `stream_to/3` exists.
- Prompt-cache hint for Anthropic: mapped (`cache: true` becomes `provider_options: [cache_control: ...]` for
  the anthropic provider, dropped for others), not measured: no Anthropic key here.
- The `:google` and `:anthropic` and plain `:openai` mappings are written and not measured live.
- OpenRouter's free pool rate-limits under repeated runs; a paid key or a second free id in the registry would
  make the live suite steadier. `nvidia/nemotron-3.5-lightning:free` passed the same probe on 2026-09-20.
