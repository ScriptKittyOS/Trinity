# Slice 011 — LLM provider layer

| Field | Value |
|---|---|
| Phase | 1 Core loop |
| Milestone | M1 Talks |
| Size | M |
| Depends on | 010 |

## Goal
`Trinity.LLM` public API and `Trinity.LLM.Provider` behaviour; `Trinity.LLM.Providers.ReqLLM` implementation with
streaming text, tool-call events, structured output, embeddings, and normalised usage; model registry from config;
Mox mock; opt-in live tests against at least one real provider.

## Why
Provider-agnostic by construction (Vision goal 6). Sessions never see a vendor SDK.

## Scope
**In:**
- Behaviour callbacks: `stream(request, opts, emit_fn)`, `generate(request, opts)`, `generate_object(request, schema, opts)`, `embed(texts, opts)`, `models/0`, `capabilities(model)`.
- `%Trinity.LLM.Request{}`: system, messages (our `messages` rows → provider format), tools (JSON schema list), model, params.
- Event stream shape (single source of truth for 012/013): `{:text_delta, s}`, `{:tool_call_start, id, name}`, `{:tool_call_delta, id, json_chunk}`, `{:tool_call_end, id, args}`, `{:usage, map}`, `{:done, reason}`, `{:error, reason}`.
- req_llm adapter: map our request to `ReqLLM.stream_text/3`, `generate_text/3`, `generate_object/4`; map providers `anthropic`, `openai`, `openrouter`, `google`, and `openai_compatible` (Ollama/LM Studio via base_url).
- Model registry: config list of `{id, provider, model, caps, price}`; `Trinity.LLM.models/0`, `default_model/0`.
- Retry/fallback: transient errors retried with backoff (config); optional fallback model list.
- Prompt caching hint pass-through for Anthropic.
- Usage normalisation → `usage_events` insert (table defined here; ledger UI in 090).
- Mox: `Trinity.LLM.ProviderMock`; `test/support/fake_provider.ex` that streams a scripted response with tool calls.
- Live tests `@tag :live` reading keys from env; excluded by default.
**Out:**
- Cost budgets/UI (090), vision/audio inputs (later slice), provider OAuth flows.

## Design notes
- `emit_fn` is called in the caller's Task; the Session subscribes via messages, not callbacks (012 decides the plumbing; expose both `stream/3` with fn and `stream_to/3` with pid).
- Keys read from `Trinity.Config.secret/1` (env now; keychain in 100).

## Deliverables
- `lib/trinity/llm/{provider,request,event,registry,retry}.ex`, `lib/trinity/llm/providers/req_llm.ex`, `lib/trinity/llm.ex`, migration `usage_events`, tests, `VERSIONS.md` (req_llm ✅ with version).

## Acceptance criteria
1. [auto] FakeProvider-driven test shows a full event sequence: text deltas → tool_call events → usage → done.
2. [manual] `generate_object/3` returns a validated map for a given JSON schema (fake) and (live-tagged) for one real provider.
3. [auto] `embed/2` returns vectors of the declared dimension (fake + live).
4. [auto] Transient error → retried N times then `{:error, _}`; non-transient → immediate error (tests).
5. [auto] A `usage_events` row is inserted per completed call with tokens and cost computed from the registry price.
6. [manual] `mix test --only live` passes against at least one configured provider on the developer machine (output pasted; keys redacted).
7. [auto] Switching `default_model` in config changes the provider used with no code change (test).

## Proof required
- Test outputs, live test output (redacted), a sample `usage_events` row.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2** — `generate_object/3` returns a validated map for a given JSON schema (fake) and (live-tagged) for one real provider.
- **AC6** — `mix test --only live` passes against at least one configured provider on the developer machine (output pasted; keys redacted).

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] VERSIONS updated · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s011): complete slice 011 — LLM provider layer` · tag `slice/011`

## Risks / open questions
- req_llm event shapes may differ per provider; the normalisation layer is the contract — test it per provider in live tests.
