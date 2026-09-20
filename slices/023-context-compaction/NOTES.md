# Slice 023: NOTES

## Two facts measured 2026-09-20 before any code

**No tokenizer, no context length, from the provider layer.** `req_llm` 1.22 exposes no tokenizer; its
`priv/supported_models.json` (431 entries) carries status and a last-checked date per model and no context
window, and neither of the owner's models is in it (`grep ling`, `grep nemotron`: one unrelated nemotron entry).
So `Trinity.Memory.Tokens` estimates: bytes over four plus a fixed overhead per message, the shape of every
Latin-script tokenizer's average, with the error margin measured against a live `usage.input_tokens` in the
eval run and written here. The context window is a registry entry's `context_tokens` (config), and an entry
without one is treated as 32,768, a floor no current chat model is below; the owner's two entries in
`config/llm.exs` carry no number yet, because none in this tree is derived from the provider's page, and a
typed number is what CLAUDE.md §8 forbids. Follow-up: the owner writes the windows in, from the provider's page.

**The fake's `generate_object/3` answers `"fake"` for every string**, so the compaction the tests exercise has a
summary of `"fake"`; the tests assert the mechanics (the row, its range and digests, the tokens dropping, the
lineage) and the eval harness with the real model asserts the quality (AC4, manual).

## G1 plan, 2026-09-20

Tree at `a579b9f` on `main` (022 approved); branch `slice/023-context-compaction`; ROADMAP row 023 to
`in_progress` in this commit. Each line names its test.

1. `Trinity.Memory.Tokens`: `estimate/1` over text, a message or a request (bytes over four, plus four per
   message), `context_tokens/1` per registry entry (`context_tokens`, default 32,768), `thresholds/1` (soft 70 %,
   hard 90 %, configurable). The test entries get `context_tokens: 3_000`. Tests: a known text's estimate; the
   thresholds; the default for an entry without a window.
2. `Trinity.Memory.Compactor`: `plan/2` (pure: given the history and a keep-count K of recent messages, the range
   `[from_seq, to_seq]` to summarise, skipping what an earlier compaction covers), `compact/3` (the LLM through
   `generate_object/3` with the schema `{summary, open_threads, decisions, facts}`; the result a `system` row
   with `parts.compaction` = the range, the digests of the summarised rows' parts, the four fields, and
   `parts.taint` the maximum of the inputs' (M1)). Nothing is deleted or edited: the originals stay as they are
   and the compaction row points at them (a deviation from `parts.compacted_by`, below). Tests: the plan over a
   fixture; a compaction row's shape; taint inheritance; idempotence (a second compaction over the same range
   is refused).
3. `Prompt.build/4` reads the newest compaction: its summary joins the system prompt (inside an `<untrusted>`
   block when tainted) and the rows it covers leave the message list. Test: the request after a compaction
   carries the summary and none of the covered rows.
4. The Session: before a model call, `Tokens.estimate/1` of the request; over the soft threshold the machine
   enters `compacting` (012's empty state), the Compactor runs in a Task, the row is written, then the call
   proceeds; over the hard threshold after compaction, the fork: a child session (`parent_id`) whose first
   message is the compaction and whose second is the user's message, the parent closes the turn with an
   assistant row naming the child and broadcasts `{:forked, child_id}` (an eighth event shape, added to
   `Events` with its test). Tests: AC1 (200 fake turns, compaction at the soft threshold, the next estimate
   under it, numbers in the assertion), AC2 (200 rows remain, the range on the compaction row), AC3 (a kill in
   `compacting`: after the restart the next message compacts once; no two compaction rows share a range), AC6
   (the hard limit forks; the child has the compaction first and the message second; the event is broadcast).
5. UI: the token indicator in the chat's bar (`estimate / context`, from the history and the model's window,
   updated per message), the compaction card (a system row with `parts.compaction`: collapsible, the four fields,
   "view original" anchors to the first covered row), the redirect on `{:forked, id}`. Tests: the indicator's
   text; the card renders; the redirect.
6. The eval harness: `test/evals/compaction/` with three scripted long conversations carrying named facts;
   `@tag :eval` (excluded by default); with the fake it proves the plumbing, with `TRINITY_LIVE=1` and the real
   model it compacts each conversation, asks for the facts back, and writes a table (facts tracked, survived,
   ratio, the token estimate against the real `usage`) to `proof/`. AC4's threshold is 90 %. Run here with the
   owner's OpenRouter model if the key is in `.env`; the owner's own run is the manual queue.
7. docs/05 (the compaction row's parts, lineage as built), docs/01 (the compacting state), docs/07 (the taint
   of a summary).
8. Gate, coverage row, PROOF.md, ROADMAP to `done`, pull request (signed merge body), tag.

Manual verification queue, for the owner at G4:
- **AC4**: `set -a; . ./.env; set +a; TRINITY_LIVE=1 mix test --only eval test/evals/compaction`: three
  conversations compacted by the real model; the table lands in `slices/023-context-compaction/proof/`; the
  ratio is at or above 0.9.
- **AC5**: `scripts/dev_chat_on_test_registry.sh` (or the fake flag in dev), a session, enough messages to cross
  the window (the test registry's window is 3,000 tokens): the indicator climbs, the compaction card appears.
  Screenshot.

Deviations from SLICE.md, stated before building: compacted rows are not marked (`parts.compacted_by` would be
an edit of an append-only row beyond the one edit docs/05 allows); the compaction row's range is the pointer, and
the prompt builder reads it. The compaction is a `system` row rendered into the system prompt rather than a
message in the list, because the providers take one system text and a mid-list system message is not portable.
The fork carries the user's message into the child rather than answering it in the parent, so the child is
where the conversation continues from its first turn.

## Lines 1 to 7, 2026-09-20: what was built, and what building it found

**Built.** As planned, with the corrections below: `Trinity.Memory` (boundary), `Memory.Tokens`,
`Memory.Compactor`, the Session's `start_turn` (compacting, then thinking or the fork), the `{:compaction, row}`
and `{:forked, id}` events, the prompt's folding, the context indicator, the compaction card, the redirect, the
eval harness with its table, `scripts/dev_chat_compaction.sh`; the fake's `object/1` and `object_delay/1`.

**Found while building, each recorded rather than smoothed.**

1. **The estimate was low by a wide margin.** Against openrouter:ling's own count for the structured
   compaction call, four bytes a token gave 287 where the provider counted 848 on one run and 540 on another
   (the call's schema and the tool definition are part of what the provider counts); against nvidia:nemotron,
   353 where it counted 885 and 919. The estimate is now three bytes a token, which errs high (an early
   compaction is the cheap mistake), and the constant the provider adds for a structured call is outside the
   estimate by design: the model call the Session sizes is the chat call, not the compaction's.
2. **openrouter:ling answers no object one time in three**, on the same transcript: thinking and text and no
   tool call (`{:ok, nil}` from the provider layer, three identical calls in a row). The provider now turns a
   missing object into a transient error the existing retry covers; when the retries are exhausted, the
   compactor falls back to a plain generation asked for JSON and parses it; when that is not JSON, the text is
   the summary. An object with every field empty (seen once) takes the same fallback.
3. **The free tier ran out.** OpenRouter's free-models-per-day limit was reached during the measurement
   (HTTP 429), so the eval table is from nvidia:nemotron, picked with `TRINITY_EVAL_MODEL`; the same harness
   ran on ling before the limit with 6 of 6, 6 of 6 and an empty object on the third conversation.
4. **The sandbox's ownership timeout disconnected the eval mid-run** (120 s; nemotron takes about 40 s per
   compaction with the fallback); `DataCase` takes an `ownership_timeout` tag, the eval sets 30 minutes.
5. **The tool surface is a third of a small window**: the fourteen tools' schemas estimate at 1,521 tokens, so
   the test registry's window is 6,000 rather than the 3,000 first tried, and the crash test's message is sized
   between the thresholds with the tools counted.
6. **A compaction that cannot help forks at once**: a single message over the hard threshold with nothing
   older to summarise (`plan/2` says `:nothing`) goes straight to the fork rather than to the model call; the
   test's message is preceded by ten short turns so the fork carries a compaction.
7. **The fork's child must hold the message before the broadcast**: the page navigated on `{:forked, id}` and
   read the child before the parent had appended to it. The order is child first, broadcast second.
8. **The compaction's first instruction lost the city.** With "keep every concrete fact" nemotron's summary of
   the Lisbon trip named no Lisbon and no flight number (16 of 18, 0.889); with "every proper noun, number,
   date, code, path and identifier ... verbatim in the facts list" it kept 17 of 18 (0.944); the one missing
   is "budget of 1200 euros", present as "1200 euro budget", which the substring check does not accept. The
   check is strict on purpose and the phrase is recorded.
9. **Two tests that had waited for the first `{:state, :idle}` after mount read the init's**: the page's
   `live/2` starts the session and its init broadcasts idle before the turn; one waited for the final message
   instead, the other was the crash test's threshold arithmetic after finding 1.

```
$ mix test test/trinity/memory test/trinity_web/live/compaction_live_test.exs   → 9 passed
$ TRINITY_LIVE=1 TRINITY_EVAL_MODEL=nvidia:nemotron mix test --only eval test/evals/compaction → 1 passed, 0.944
$ mix gate                                                                     → exit 0; 264 passed, 12 excluded; plan_check: PASS
$ mix test --cover                                                             → 75.39% total (Session 87.31%, Tokens 85.71%, Compactor 72.13%)
$ mix credo --strict --all                                                     → 1120 mods/funs, found no issues
```

## Follow-ups
- The owner writes `context_tokens` for `openrouter:ling` and `nvidia:nemotron` into `config/llm.exs` from the
  providers' pages; until then both run on the 32,768 floor and compact early.
- The estimate's constant for a structured call (the schema) is not modelled; 090's cost ledger can compare the
  estimate with every recorded `usage` row and report the drift.
- Compaction emits no candidate memories yet; 032 consumes the compaction rows' `facts`.
- The "view the original" link scrolls within the page; when 031's search lands, the covered range can open
  in a filtered view.
- `Compactor` at 72 % coverage: the text-fallback branches are exercised live, not in the suite; a Mox
  provider test for the fallback is a small addition.

10. **The postgres job caught a third test reading the init's idle** (run 35534378835: the indicator test, "both
    sides are exactly equal"): the same race as finding 9, invisible on SQLite's timing and visible on the
    slower pool. It waits for the final message now. Recorded as a pattern: after `live/2` mounts a session's
    page, a test that waits on `{:state, :idle}` alone waits on nothing.
