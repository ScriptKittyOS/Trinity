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
