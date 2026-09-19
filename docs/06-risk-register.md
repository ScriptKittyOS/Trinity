# 06: Risk register

| # | Risk | Likelihood | Impact | Trigger / early warning | Mitigation | Owner slice |
|---|---|---|---|---|---|---|
| R1 | Desktop packaging chain (Burrito/ex_tauri) lags OTP or lacks Windows | High | High | Slice 001 spike fails on a target OS | Spike first; fallback matrix: ex_tauri → plain Tauri sidecar with hand-rolled Rust → elixir-desktop → local-server+tray | 001 |
| R2 | macOS notarization / Windows HSM signing friction | High | Med | 101 blocked on certs | Start cert procurement at M0; Windows 460-day cert cap (from Mar 2026) noted; unsigned dev builds allowed until 101 | 101 |
| R3 | EXLA/Bumblebee binary size and RAM on user machines | Med | Med | 032 measurement > 300 MB or embed > 500 ms | Behaviour lets us switch to hosted embeddings; or Ortex despite stall | 032 |
| R4 | sqlite_vec extension not loadable inside Burrito bundle | Med | Med | 032 on packaged build | Vendor the extension in `priv/`; fallback Nx brute-force over an ETS cache | 032 |
| R5 | req_llm breaking changes / provider drift | Med | Med | Live tests fail after bump | Behaviour isolates it; LangChain-Elixir fallback | 011 |
| R6 | LiveView streaming performance (token spam) | Med | Low | UI lag at > 20 msg/s | Coalescing broadcaster; phoenix_streamdown | 013 |
| R7 | Context compaction loses critical information | Med | High | Eval set regression | Always-on tier preserved verbatim; compaction eval harness in 023 | 023 |
| R8 | Prompt injection via tool output / skills / web | High | High | none | Untrusted-content framing; scanner on skills; permission gate on side effects; see 07-security-model | 021, 041 |
| R9 | Oban on SQLite limitations (no Pro workflows) | Low | Med | Need for multi-step durable graphs | Postgres path kept alive in CI matrix | 050 |
| R10 | Agent scope creep across slices | Med | Med | PROOF shows work outside spec | CLAUDE.md rules; NOTES follow-ups; human review | all |
| R11 | Stale or single-maintainer libs (**boundary**, hnswlib, ex_tauri, sqlite_vec, nostrum, telegex) | High | Med–High | No release in 6 months. Measured 2026-09-05: boundary 2024-09-25, sqlite_vec 2024-11-19, telegex 1.9.0-rc.0 2024-09-18, nostrum 2025-03-02, the trigger already fires for four of them | All behind behaviours; vendor if needed. **boundary is the highest-consequence one**: ADR-0001, docs/01, CLAUDE.md §5 and Slice 000 AC4 all rest on it, and it is unverified on Elixir 1.20. Probe it before anything is built on it | 000, 032, 072 |
| R12 | Secrets leak into logs/DB/commits | Low | High | grep hits in CI | `mix gate` includes a secret scan (gitleaks-style regex) from 000; Secrets module from 100 | 000, 100 |
| R13 | Scope drifts toward matching other agents' breadth instead of shipping depth | Med | Low | Slice scope grows during a phase | Non-goals in docs/00 are binding; breadth is a later decision, not a default | none |
| R14 | Elixir MCP libraries lag the 2026-07-28 spec; the one that claims it is weeks old | High | Med | 059 probes fail | Behaviour boundaries; own minimal stateless server as fallback; fastest_mcp/gen_mcp/anubis compared by measurement | 059 |
| R15 | anubis_mcp is LGPL-3.0 | Med | Med | It wins the 059 spike | Legal review before adoption in a distributed binary; prefer Apache or MIT candidates | 059 |
| R20 | Foundation donation may require transferring assets or marks the project intends to keep | Med | Med | Proposal drafting (122) | Unverified: the requirement is asserted from an announcement, not from the charter text. Read the charter, then decide what is offered and what is retained. Legal review before any proposal leaves the tree | 122 |
| R21 | The tree carries IP that is not this project's to publish | Med | High | Any design in Trinity that reproduces a third party's protected mechanism | Trinity's receipt and policy design is its own. Policy identifiers stay out of `signed_payload` until legal review clears them; 024's field set is reviewed before that slice starts | 024, 120, 122 |
| R22 | Single maintainer; Growth needs two unaffiliated production users and commits from two orgs | High | Med | 6-month Sandbox checkpoint | Sandbox tolerates it; GOVERNANCE.md documents intent to grow; recruit co-maintainers via the Elixir community once public | 120, 122 |
| R23 | EMA / ID-JAG is beta everywhere (vendors label it so); IETF draft still moving | Med | Med | Spec revision breaks the exchange | Keep the AS small and behaviour-driven; pin the draft version in the ADR; conformance tests against two IdPs' documented flows | 062 |
