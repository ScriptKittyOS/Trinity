# ADR-0003 — req_llm behind `Trinity.LLM.Provider`
Status: accepted · Date: 2026-09-05

## Context
We need many providers, streaming, tool calls, structured outputs, usage/cost, prompt caching, and local model
support. Candidates: req_llm, LangChain-Elixir, hand-rolled Req clients.

## Decision
`Trinity.LLM.Provider` is our behaviour; `Trinity.LLM.Providers.ReqLLM` is the default implementation wrapping
req_llm. Sessions call `Trinity.LLM` only. Local models are reached through req_llm's OpenAI-compatible base_url.

## Consequences
- Provider swap is config. Tests mock the behaviour.
- If req_llm stalls, a LangChain-backed implementation of the same behaviour is the fallback.
- Usage/cost metadata is normalised by our layer into `usage_events`.
