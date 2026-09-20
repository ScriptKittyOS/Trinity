# Proof for slice 011: LLM provider layer

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/011-llm-provider-layer · Final commit: `49005dc` (filled by the commit after it)

## Summary
`Trinity.LLM` is the one door to a model: a registry id names the provider module, transient errors retry with
backoff, and a completed call writes one `usage_events` row with cost from the registry price. The seven event
shapes 012 and 013 consume are fixed in `Trinity.LLM.Event`. The req_llm adapter is split into the half that
talks and a pure `Mapping` half tested over recorded chunk sequences. The live suite against OpenRouter and the
NVIDIA endpoint found four defects on its first runs (a merge-order bug, a 30-second stream timeout, a wrapped
429 called permanent, an embedding capability the inline spec had to declare); each is fixed with its reason in
the code and pinned by a test. Deferred: `Trinity.LLM.Supervisor` until a Session needs a process (NOTES.md
Follow-ups). Keys reach a provider only through `Trinity.Config.secret/1`; none appears in this file.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup)
385 mods/funs, found no issues.
No vulnerabilities found.
Result: 138 passed, 10 excluded
trinity.coverage: 010 44.88% vs 001 30.37%: OK
plan_check: PASS
exit=0
```

## Tests
```
$ mix test --cover
Result: 138 passed, 10 excluded
|     51.57% | Total |
|     86.11% | Trinity.LLM.Providers.ReqLLM.Mapping |
|      0.00% | Trinity.LLM.Providers.ReqLLM         |   (the half that talks; the live suite covers it)
```
`coverage.tsv` row: `011  51.57  ec5334a  2026-09-20`. `trinity.coverage: 011 51.57% vs 010 44.88%: OK`.

## Acceptance criteria evidence

### AC1: FakeProvider-driven test shows a full event sequence: text deltas, tool_call events, usage, done
```
$ mix test test/trinity/llm/llm_test.exs --trace
* test default_model (AC7) an unknown model id is refused by name
* test default_model (AC7) an unknown model id is refused by name (0.06ms)
* test default_model (AC7) switching default_model in config changes the provider used, with no code change
* test default_model (AC7) switching default_model in config changes the provider used, with no code change (0.4ms)
* test embed/2 (AC3) returns one vector per text of the declared dimension
* test embed/2 (AC3) returns one vector per text of the declared dimension (0.1ms)
* test retry (AC4) a permanent error returns at once with one attempt
* test retry (AC4) a permanent error returns at once with one attempt (0.05ms)
* test retry (AC4) a transient error is retried and then succeeds
* test retry (AC4) a transient error is retried and then succeeds (4.8ms)
* test retry (AC4) attempts exhausted returns the error, named as exhausted
* test retry (AC4) attempts exhausted returns the error, named as exhausted (4.3ms)
* test retry (AC4) no usage row is written for a failed call
* test retry (AC4) no usage row is written for a failed call (0.1ms)
* test stream/3 (AC1) emits the full sequence: text deltas, tool call start, deltas, end, usage, done
* test stream/3 (AC1) emits the full sequence: text deltas, tool call start, deltas, end, usage, done (0.6ms)
* test stream/3 (AC1) stream_to/3 delivers the same events as messages and then llm_done
* test stream/3 (AC1) stream_to/3 delivers the same events as messages and then llm_done (0.1ms)
* test usage_events (AC5) embed and object calls record their own kinds
* test usage_events (AC5) embed and object calls record their own kinds (23.7ms)
* test usage_events (AC5) one row per completed call, cost from the registry price
* test usage_events (AC5) one row per completed call, cost from the registry price (0.2ms)
* test usage_events (AC5) the session id is recorded when given
* test usage_events (AC5) the session id is recorded when given (6.3ms)
Result: 20 passed
```
The AC1 test asserts the exact list: two `text_delta`, `tool_call_start`, two `tool_call_delta`,
`tool_call_end` with `%{"city" => "Paris"}`, `usage`, `done :tool_calls`; every event passes `Event.valid?/1`.
`stream_to/3` delivers the same as messages with a `{:llm_done, ref, result}` last.

### AC2: [manual] generate_object/3 returns a validated map for a JSON schema (fake) and (live) for one real provider
Fake: `generate_object/3 returns a map shaped by the schema` (above). Live, both providers, from the live trace
below: `openrouter:ling generate_object returns a map that validates against the schema (AC2)` and
`nvidia:nemotron generate_object ...` both pass; the assertion is a map with a string `city` matching Paris and a
numeric `population_millions`, both required by the schema.

### AC3: embed/2 returns vectors of the declared dimension (fake + live)
Fake: `embed/2 (AC3) returns one vector per text of the declared dimension` (8, from the registry entry).
Live: `live embed: dimension 2048` against `nvidia/nemotron-3-embed-1b`, two texts, two vectors, every element a
float.

### AC4: transient error retried N times then {:error, _}; non-transient immediate
```
* test retry (AC4) a transient error is retried and then succeeds              (fails twice on 429, third call succeeds; 3 calls)
* test retry (AC4) attempts exhausted returns the error, named as exhausted     ({:exhausted, 3, :down}; 3 calls)
* test retry (AC4) a permanent error returns at once with one attempt           (401; 1 call)
* test retry (AC4) no usage row is written for a failed call
* test Retry.run/2 backs off exponentially and stops at the attempt count       (sleeps 10, 20, 40 ms for 4 attempts)
```

### AC5: a usage_events row per completed call with tokens and cost from the registry price
```
* test usage_events (AC5) one row per completed call, cost from the registry price
    model_id "fake:chat", provider "fake", kind "chat", 10 in, 5 out,
    cost_usd 0.00002 (10 tokens at $1.00 per million + 5 at $2.00 per million), provider_meta %{"provider_cost" => nil}
* test usage_events (AC5) the session id is recorded when given
* test usage_events (AC5) embed and object calls record their own kinds
```
Live: `live usage row: 25 in, 14 out, provider_cost nil` from a real OpenRouter call, `cost_usd 0.0` because the
registry prices the free tier at 0.

### AC6: [manual] mix test --only live passes against at least one configured provider (output pasted; keys redacted)
Two providers, this machine, 2026-09-20. Keys loaded from `.env` (gitignored) and redacted by pattern in this
transcript; none appears below.
```
$ set -a; . ./.env; set +a; TRINITY_LIVE=1 mix test --only live --trace
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
Each provider ran a preflight against its `GET /models` (an id that reached end of life is a named refusal),
a streamed completion, a tool call and a structured object; the embedding model ran once; one real call wrote
a usage row. The earlier runs that found the four defects are recorded in NOTES.md as 6/10 then 8/10.

### AC7: switching default_model in config changes the provider used with no code change
```
* test default_model (AC7) switching default_model in config changes the provider used, with no code change
    default "fake:chat" streams from the fake; Application.put_env(... default_model: "mock:chat") and the same
    request streams from the Mox mock, which asserts it received the entry's model name "chat".
* test default_model (AC7) an unknown model id is refused by name
```

## Manual verification for the reviewer
AC2 and AC6 are the live runs above; the reviewer reads the transcript and, with keys in `.env`, may re-run
`TRINITY_LIVE=1 mix test --only live`. OpenRouter's free pool rate-limits under repeated runs (429, retried).

## Deviations from SLICE.md
See NOTES.md: five provider mappings written, two measured live; no `Trinity.LLM.Supervisor` until a process
needs one; `usage_events` columns are the Event usage keys and carry no latency (090's telemetry measures it);
the adapter's `models/0` returns `[]` and `capabilities/1` is fixed, the registry being the source.

## Versions touched
`VERSIONS.md` updated: yes. `req_llm` 1.24.0 and `mox` 1.3.1 read in `mix.lock`. Twelve packages entered the
lock with req_llm, listed with licences in NOTES.md line 1; all Apache-2.0 or MIT. `mix hex.outdated` not run.

## Git
```
$ git log --oneline main..HEAD
d53bfec feat(s011): the adapter's pure half is a module with recorded-chunk tests; coverage row; docs/05 synced
ec5334a feat(s011): the provider layer: behaviour, events, registry, req_llm adapter, retry, usage rows, fake and live suites
73caeb5 feat(s011): req_llm 1.24.0 and mox, with what they bring counted and licensed
b9cbcf2 docs(s011): G1 plan, and the slice opens
49005dc feat(s011): complete slice 011 (LLM provider layer)
```
