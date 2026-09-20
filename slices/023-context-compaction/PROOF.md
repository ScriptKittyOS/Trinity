# Proof for slice 023: Context compaction + session lineage

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/023-context-compaction · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Token-aware context management: an estimate of the request against the model's window before every model
call; over the soft threshold the Session summarises the older history through the model into a compaction row
(the range, the digests of what it summarised, summary, open threads, decisions, facts, the maximum taint of
its inputs) and the prompt builder renders the newest one into the system prompt and drops the rows it covers;
nothing is edited or deleted; over the hard threshold the conversation forks into a child session with
`parent_id`. The eval harness ran against a real model and 17 of 18 tracked facts survived (0.944). Nine
findings in NOTES.md, the sharpest that the estimate was low against the providers' own counts and that the
free model answers no object one time in three, both now handled.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 5989b73)
1120 mods/funs, found no issues.
... SCAN COMPLETE ...                        (sobelow --exit --skip: no finding)
No retired or security advisory packages found
No vulnerabilities found.
AC1: naive prompt 9283 tokens; after compaction 2101 tokens; soft threshold 4200; 3 compactions
Result: 264 passed, 12 excluded
trinity.coverage: 022 74.85% vs 021 72.45%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 1120 mods/funs, found no issues.

## Tests
```
$ mix test --cover                           (tree 5989b73)
Result: 264 passed, 12 excluded
    |     72.13% | Trinity.Memory.Compactor               |
    |     85.71% | Trinity.Memory.Tokens                  |
    |     85.71% | Trinity.Sessions.Prompt                |
    |     87.31% | Trinity.Sessions.Session               |
    |    100.00% | Trinity.Memory                         |
    |     75.39% | Total                                  |
```
`coverage.tsv` row: `023  75.39  5989b73  2026-09-20` (from 74.85 at 022).

The slice's nine tests (`--trace`):
```
test a compaction row renders as a card naming its range; the originals stay on the page  * test a compaction row renders as a card naming its range; the originals stay on the page (115.9ms) [L#43]
test a fork moves the page to the child session  * test a fork moves the page to the child session (3.1ms) [L#75]
test Compactor.plan/2 summarises everything before the last keep messages, skipping what a compaction covers, and nothing for a short history  * test Compactor.plan/2 summarises everything before the last keep messages, skipping what a compaction covers, and nothing for a short history (1.2ms) [L#40]
test Prompt folding the newest compaction joins the system prompt and its covered rows leave the list; an untrusted one is wrapped  * test Prompt folding the newest compaction joins the system prompt and its covered rows leave the list; an untrusted one is wrapped (1.3ms) [L#54]
test the indicator shows the estimate against the window and climbs with the history  * test the indicator shows the estimate against the window and climbs with the history (17.6ms) [L#23]
test through a Session AC1 and AC2: 200 turns compact at the soft threshold; the estimate drops; every row remains and the compaction names its range
test through a Session AC3: killed while compacting, the restart retries once and no two compaction rows share a range  * test through a Session AC3: killed while compacting, the restart retries once and no two compaction rows share a range (24.4ms) [L#131]
test through a Session AC6: past the hard threshold after a compaction, the conversation forks into a child with the compaction first  * test through a Session AC6: past the hard threshold after a compaction, the conversation forks into a child with the compaction first (10016.5ms) [L#180]
test Tokens the estimate is bytes over three plus four per message; the window and thresholds come from the entry  * test Tokens the estimate is bytes over three plus four per message; the window and thresholds come from the entry (0.5ms) [L#15]
```

## Acceptance criteria evidence

### AC1 [auto]: a 200-turn conversation triggers compaction at the soft threshold; the next prompt's estimate drops below it (numbers)
`AC1 and AC2: 200 turns compact at the soft threshold ...`: the fake answers every turn; the test registry's
window is 6,000 tokens (soft 4,200, hard 5,400; the fourteen tools' schemas alone estimate at 1,521). Printed by
the test in the gate run: **naive prompt 9,283 tokens; after compaction 2,101 tokens; soft threshold 4,200; 3
compactions**. Asserted: the estimate after compaction is under the soft threshold and the naive one over it.

### AC2 [auto]: all 200 original messages remain; the compaction message references their seq range
The same test: at least 400 non-compaction rows remain, the seqs are gapless from 1, and the newest compaction
row's `parts.compaction` carries `from_seq < to_seq`, `rows` between 2 and the span, a list of digests and a
summary; no two compaction rows end at the same seq.

### AC3 [auto]: killing the Session during compacting → restart → completed or cleanly retried; no duplicate compaction
`AC3: killed while compacting ...`: after twelve turns a message sized between the thresholds and the fake's
object call delayed three seconds; the test sees `{:state, :compacting}` and `state/1` confirms it; the kill
lands there; the restart is idle and the compaction count is unchanged (nothing half-written); the next message
compacts once (`:compacting` seen again, exactly one more compaction row); no two rows share a range or an end;
the final answer is the fake's text.

### AC4 [manual]: eval harness: ≥ 90 % of tracked facts survive across the 3 scripted conversations with a real model
Run here with the owner's keys: `TRINITY_LIVE=1 TRINITY_EVAL_MODEL=nvidia:nemotron mix test --only eval
test/evals/compaction`, 515 s. The table, `proof/eval-2026-09-20.md`:

| conversation | facts tracked | survived | ratio | missing |
|---|---|---|---|---|
| trip planning | 6 | 5 | 0.83 | "budget of 1200 euros" (present as "1200 euro budget") |
| code review | 6 | 6 | 1.0 | |
| home network | 6 | 6 | 1.0 | |
| **all** | 18 | 17 | **0.944** | |

Token calibration on the last call: the provider counted 919 input tokens for a transcript estimated at 353 with
the compaction instructions and the schema outside the estimate (NOTES.md finding 1; the estimate is now three
bytes a token). The first instruction wording measured 0.889 on the same model (finding 8). The owner's own
run is the manual queue; openrouter:ling's free tier reached its daily limit during this measurement.

### AC5 [manual]: the UI shows the token indicator and the compaction card (screenshot)
Tests: `the indicator shows the estimate against the window and climbs with the history`, `a compaction row
renders as a card naming its range; the originals stay on the page`. Screenshots from
`scripts/dev_chat_compaction.sh` (a session with twelve long turns on the test registry, the fake's compaction
object set): `proof/ac5-indicator-before.png` (context 3,071 / 6,000 before the message) and
`proof/ac5-compaction-card.png` (the card "Compacted, messages 1 to 17, 17 rows" open on its summary, the
originals still above it).

### AC6 [auto]: parent_id fork: at the hard limit a child session is created with the compaction as its first message and the UI redirects
`AC6: past the hard threshold after a compaction, the conversation forks ...`: ten short turns, then a message
larger than the window; `{:state, :compacting}` then `{:forked, child_id}`; the child's `parent_id` is the
parent; its first row is the compaction and its second the user's message; the parent's last row carries
`parts.forked_to`; the child answers its turn. The page: `a fork moves the page to the child session`
(`assert_redirect` on the broadcast).

### Platform alignment: taint and digests
The compaction row carries `parts.taint` as the maximum of its inputs and the digests of the summarised rows'
content parts (the plan and the row test); `Prompt folding`: an untrusted compaction is rendered inside an
`<untrusted source="compaction" digest=…>` block in the system prompt.

## Manual verification for the reviewer
1. AC4: `set -a; . ./.env; set +a; TRINITY_LIVE=1 TRINITY_EVAL_MODEL=nvidia:nemotron mix test --only eval
   test/evals/compaction` (or the default model once its daily limit resets). Expected: the table in `proof/`
   with a ratio at or above 0.9.
2. AC5: `mix assets.build`, remove `priv/static/assets/**/*.gz`, `scripts/dev_chat_compaction.sh`, open the
   printed port at `/s/<the printed session id>`, send "recap everything so far". Expected: the indicator
   climbs, the status passes through `compacting`, the card appears above the answer.

## Deviations from SLICE.md
See NOTES.md: the three stated at G1 (no marking of compacted rows, the compaction as a system-prompt section,
the fork carrying the message) and finding 6 (a direct fork when nothing can be compacted).

## Versions touched
`VERSIONS.md` updated: no. No dependency changed.

## Git
```
$ git log --oneline main..HEAD
5989b73 feat(s023): token estimation, compaction with lineage, the compacting state and the fork, the UI and the eval harness
352b51e docs(s023): G1 plan with the token and window facts measured, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the "Final commit" field in the header: the commit carrying this file is `32e8e44`
(`feat(s023): complete slice 023 (context compaction and lineage)`); the `git log` block above lists the
commits before it. The pull request, its merge commit (signed in its body) and the tag come after review.
