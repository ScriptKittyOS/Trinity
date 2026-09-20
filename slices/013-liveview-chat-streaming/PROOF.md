# Proof for slice 013: LiveView chat UI with streaming

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/013-liveview-chat-streaming · Final commit: (the commit carrying this file; named in the closing correction below)

## Summary
A usable chat over slice 012's Session: a sessions index at `/`, the chat at `/s/:id`, the assistant's text
streamed as markdown through one renderer (`mdex`, chosen by the measurement in NOTES.md after `earmark` turned
out to be retired with an open XSS advisory and `phoenix_streamdown` still a beta), tool cards, a model picker,
Cancel and Esc, an interrupted banner with Retry, `Ctrl/Cmd+K` for a new session, and a remount mid-stream that
shows the draft so far with neither a gap nor a duplicate. The design language is decided here as tokens (two
themes, dark by default; fonts, text sizes, radii) and a component vocabulary later surfaces take. Every browser
response carries a Content-Security-Policy with a per-request nonce, the debt slice 000 left to this slice. The
hard parts, all in NOTES.md: tool rows have no event of their own (the page reads past its last seen `seq`), a
stream container cannot hold the in-progress message, the formatter reflowed a pre-wrap element, and the fake
provider had to move into `lib/` for the dev flag the slice asks for.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 080c543)
596 mods/funs, found no issues.
... SCAN COMPLETE ...                        (sobelow --exit --skip: no finding)
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 83 locked packages, none disagreeing with 47 pins
versions.gen: VERSIONS.md already matches Trinity.Versions and mix.lock
trinity.names: OK over 266 tracked files
trinity.secrets.scan: OK over 266 files
trinity.reuse: OK. Every commentable tracked file carries an SPDX header
AC7: 6 renders of the page for 1,000 deltas
Result: 176 passed, 10 excluded
trinity.coverage: 012 60.82% vs 011 51.57%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 596 mods/funs, found no issues. `mix assets.build`: exit 0 (tailwind 4.3.0, daisyUI
5.5.20, esbuild; CI builds no assets, so this run is the record).

## Tests
```
$ mix test --cover                           (tree 080c543)
Result: 176 passed, 10 excluded
    |     17.07% | TrinityWeb.CoreComponents              |
    |     50.00% | TrinityWeb.ErrorHTML                   |
    |     67.48% | TrinityWeb.ChatComponents              |
    |     80.00% | TrinityWeb.Markdown                    |
    |     81.25% | Trinity.LLM.Providers.Fake             |
    |     81.58% | TrinityWeb.SessionLive.Show            |
    |     84.66% | Trinity.Sessions.Session               |
    |     91.67% | TrinityWeb.SessionLive.Index           |
    |    100.00% | TrinityWeb.Layouts                     |
    |    100.00% | TrinityWeb.Plugs.ContentSecurityPolicy |
    |     64.41% | Total                                  |
```
`coverage.tsv` row: `013  64.41  080c543  2026-09-20` (from 60.82 at 012).

The slice's tests, `mix test test/trinity_web test/trinity/sessions/model_and_persona_test.exs --trace`:
```
test GET / sets the policy and the theme script carries the same nonce (67.2ms)
test two requests get two nonces (1.1ms)
test raw HTML in the answer is omitted, block and inline (5.0ms)
test a javascript: href is emptied and ordinary links get rel=noopener (2.8ms)
test markdown structure renders: emphasis, code, list, table, fence (14.2ms)
test streaming completes an unfinished fragment; a finished render is not touched (28.4ms)
test the same text renders the same HTML twice (4.8ms)
test the index lists sessions, and New session creates a row and opens it (4.2ms)
test the index Ctrl/Cmd+K reaches the same event through the Shortcuts hook (2.5ms)
test the index a missing session redirects home with a flash (2.1ms)
test a turn (AC2) send, deltas update the draft, the final message appears once (538.0ms)
test cancel (AC3, the test half) the partial text is kept as interrupted, the banner shows, Retry sends again (66.7ms)
test cancel (AC3, the test half) Esc reaches cancel through the Shortcuts hook (59.5ms)
test the Session dies under the page (AC4, the test half) the banner appears without a reload, the page stays usable, the next message works (769.3ms)
test a remount mid-stream (AC5) history comes from the database, the draft so far from the process; nothing doubles or goes missing (813.5ms)
test the model picker (AC6) changes sessions.model and the next turn uses it (7.7ms)
test render count (AC7) 1,000 deltas in well under a second render the page at most 25 times
test default_persona/0 creates the row named default once and returns the same row after (1.2ms)
test set_model/2 (AC6's core) refuses an id the registry does not know, and the row is unchanged (0.5ms)
test set_model/2 (AC6's core) refuses a session that does not exist (2.0ms)
test set_model/2 (AC6's core) the next turn of a running session uses the model set between turns (31.0ms)
test state/1 carries the in-progress text mid-stream the view holds what has arrived; idle it is empty (403.4ms)
```
The red for the Session change was committed first (`ce4b1f4`, "the next turn of a running session uses the
model set between turns": `left: nil, right: "fake:embed"`) and the fix references it (`57aca61`).

## Acceptance criteria evidence

### AC1 [manual]: create session, send "hello", see the streamed markdown response (fake provider and a real provider), screenshot
Taken here from the dev server driven by a headless chromium (NOTES.md, deviations); the owner's own run is the
manual queue below.
- Fake provider (`TRINITY_FAKE_PROVIDER=1 mix phx.server`, the `:demo` script): `proof/ac1-streaming-fake.png`
  (mid-stream: bold, list, an open fence completed, the cursor, status `thinking`, Cancel showing) and
  `proof/ac1-final-fake.png` (the whole answer: fence, table, blockquote, the `<script>` in the answer dropped,
  usage badge `12/95`, status `idle`).
- Real provider (`set -a; . ./.env; set +a; mix phx.server`, model `openrouter:ling`):
  `proof/ac1-streaming-openrouter.png` and `proof/ac1-final-openrouter.png` (two paragraphs and a list, usage
  `43/276`). The browser console reported no error under the strict policy in either run.

### AC2 [auto]: send → assistant_delta updates → the final message appears once in the DOM
`a turn (AC2) send, deltas update the draft, the final message appears once`: after the first delta the draft
element is present, status `thinking`, Cancel present; after `{:state, :idle}` the final text occurs exactly
once in the rendered page (`length(String.split(html, final)) - 1 == 1`), the draft is gone, both rows of
`history/1` have their elements, the usage badge reads `29/29`, and the session's title is the first message.

### AC3 [manual]: cancel during streaming; interrupted message with banner (test + screenshot)
Test: `cancel (AC3, the test half) the partial text is kept as interrupted, the banner shows, Retry sends again`:
Cancel mid-stream; the banner and the `interrupted` label render; the partial text is on the page and the
rest never arrives; the row carries `parts.interrupted == true`; Retry sends the same message again and the
banner clears; history is `["user", "assistant", "user", "assistant"]`. `Esc reaches cancel through the
Shortcuts hook` drives the same event the key pushes. Screenshot: `proof/ac3-cancelled.png` (Esc pressed
mid-stream: the partial answer marked interrupted, the banner with Retry, the composer enabled again).

### AC4 [manual]: kill the Session process while the page is open: banner appears; page remains usable; next message works (manual + test)
Test: `the Session dies under the page (AC4, the test half) ...`: `Process.exit(pid, :kill)` after a draft row
exists; the page process is alive; the banner appears from the new incarnation's rehydrate broadcast, without a
reload; the kept text is on the page; status `idle`; the new pid differs; the next message completes and
history is four rows. Screenshots: `proof/ac4-killed-banner.png` (the kill from a second node with
`:rpc.call(node, Process, :exit, [pid, :kill])` while streaming: the partial answer marked interrupted and the
banner) and `proof/ac4-next-message-works.png` (the next message answered in full).

### AC5 [auto]: reload mid-stream: history from DB; no duplicate or missing messages
`a remount mid-stream (AC5) ...`: two earlier rows, a turn in flight with "one two " received; a second page
mounted for the same session shows both earlier rows and "one two" in the draft; after idle the final text
occurs once, the draft is gone, every one of the four rows in `history/1` has its element on both pages, and the
page holds exactly four message elements.

### AC6 [auto]: the model picker changes sessions.model and the next turn uses it
`the model picker (AC6) changes sessions.model and the next turn uses it`: the picker shows `fake:chat` selected
(the registry default); changing to `mock:chat` writes `sessions.model` and re-selects; changing to `fake:embed`
and sending a message, the fake's `last_request/0` carries `model: "fake:embed"`. Its core, in the Sessions
suite: the same through `Sessions.set_model/2` on a running process whose pid does not change; an unknown id and
a missing session refused by name.

### AC7 [auto]: 1,000 deltas in 1 s do not exceed ~25 DOM patches; number recorded
`render count (AC7) ...`: a handler on `[:phoenix, :live_view, :render, :stop]` counts renders in the page's
process while the fake streams 1,000 single-character deltas; **6 renders** (printed by the test in every gate run
above), asserted `<= 25`; the final page holds all 1,000 characters. Each render is one diff to the client, so the
patch count is at most the render count.

### AC8 [auto]: gate green; mix sobelow no new findings
The gate block above, exit 0. `mix sobelow --exit --skip` exits 0; `mix sobelow --exit` (no skip file) reports the
same set as before the slice plus the one `raw/1`, which carries a scoped `@sobelow_skip` with its reason; the
slice-000 CSP skip is rekeyed with the reason that the policy is now set by a plug sobelow cannot see (the test
asserts the header).

### The design language
`assets/css/app.css` (two themes, `@theme` tokens), `docs/03-conventions.md` UI section, `TrinityWeb.ChatComponents`.
`proof/design-light-theme.png` is the same chat under the light theme; every other screenshot is the dark default.

## Manual verification for the reviewer
1. AC1: `TRINITY_FAKE_PROVIDER=1 mix phx.server`, open `http://localhost:4000/`, New session, type "hello", Enter.
   Expected: the answer streams in as markdown with a cursor, status `thinking`, then `idle` with a usage badge.
   Then `set -a; . ./.env; set +a; mix phx.server` and the same with `openrouter:ling` in the picker.
2. AC3: with the fake provider, send anything and press Esc (or Cancel) while it streams. Expected: the partial
   answer stays, labelled `interrupted`, the banner offers Retry, the composer is enabled.
3. AC4: with the page open mid-stream, in `iex -S mix phx.server`: `Process.exit(Trinity.Sessions.whereis("<id from the URL>"), :kill)`.
   Expected: the banner appears without a reload, status returns to `idle`, the next message is answered.

## Deviations from SLICE.md
See NOTES.md: `mdex` rather than `phoenix_streamdown` (measured); the fake provider in `lib/` for the dev flag;
two changes in 012's modules (the row re-read per turn, `state/1` with `text`); the CSP here because the
slice-000 skip named 013; screenshots taken here as well as left to the owner; shortcuts through one hook; the
`LocalTime` hook.

## Versions touched
`VERSIONS.md` updated: yes. `mdex ~> 0.13` added (row new, ✅ in `mix.lock`); `phoenix_streamdown` reads not used
with the measurement. `mix.lock` gained `mdex` 0.13.5, `mdex_native` 0.2.8, `rustler_precompiled` 0.9.0.
`mix hex.audit` and `mix deps.audit` clean. The `package` workflow run triggered by this branch's `mix.lock`
change is cited in the closing correction below once it has run.

## Git
```
$ git log --oneline main..HEAD
080c543 fix(s013): the inline sobelow skip names its reason the way the enforcer reads it
84a4aba test(s013): the kill test waits for the rehydrate broadcast only
e33f5bc fix(s013): a user bubble keeps its own whitespace only
50f35db feat(s013): the chat: two LiveViews, the component vocabulary, the renderer, the policy
57aca61 fix(s012): the Session reads its row at the start of every turn
ce4b1f4 test(s013): a model set between turns is not the next turn's model (red)
482b9e6 chore(s013): add mdex ~> 0.13
454a12e docs(s013): G1 plan with the renderer measured, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the "Final commit" field in the header: the commit carrying this file is `8cc90b7`
(`feat(s013): complete slice 013 (LiveView chat UI with streaming)`), and the `git log` block above lists the
commits before it. The `package` workflow run and the pull request are named in a later correction once they exist.

## Correction, 2026-09-20: the packaged binary, after the owner's decision
Supersedes the "Versions touched" paragraph's last sentence and adds to AC1 and AC8. The `package` workflow,
dispatched by hand (runs 35518054546 and 35519205973), found three things (NOTES.md findings 12 to 15): the
packaged binary never ran a migration (`fix(s010)`), the mdex NIF does not load in Burrito's musl ERTS, and a
musl build of it linked through Zig does. The owner chose to keep mdex with that build. Measured here on a fresh
install (`rm -rf ~/.local/share/.burrito`, a fresh `DATABASE_PATH`) of the linux binary built exactly as the
workflow builds it:
```
$ readelf -d _build/prod/lib/mdex_native/priv/native/mdex_native_nif.so | grep NEEDED
 0x0000000000000001 (NEEDED)             Shared library: [libc.so]
$ ./burrito_out/desktop_linux_x86_64 --no-halt --smoke      (three runs)
TRINITY_SMOKE_PORT=44875
TRINITY_SMOKE_MARKDOWN=ok                                    exit 0, each run
$ (the gnu artifact copied over the NIF in the extracted payload)
TRINITY_SMOKE_MARKDOWN=failed:%MDEx.DecodeError{document: #MDEx.Document(0 nodes)<>, error: nil}   exit 3
```
The packaged chat against `openrouter:ling` renders the answer as markdown with no `on_load` warning in the
log: `proof/ac1-final-openrouter-packaged.png`. `VERSIONS.md` gained the `rustler` row (build time only);
`versions.verify`: 84 locked packages, 48 pins. Gate on this tree: exit 0, 177 tests. The `package` run on the
final tree is named in the next correction.

## Correction, 2026-09-20: the package run on the decided tree
Supersedes "the `package` run on the final tree is named in the next correction" above. Run **35521749862**
(dispatched on `22cd58c`'s tree, the musl NIF build): **linux x86_64 green end to end**, the NIF compiled from
source in the job, the smoke step reading `TRINITY_SMOKE_MARKDOWN=ok`, the serve step HTTP 200. **macOS
aarch64 and windows x86_64: the smoke step passed on both**, `TRINITY_SMOKE_MARKDOWN=ok` from the precompiled
artifact on each, so the renderer's NIF loads on all three operating systems; both then failed the serve step
exactly as the slice/011 and slice/012 tag runs did before this slice, with an empty log (the port loop timing
out). The step now prints `serve.log` on that path too (`fix(s001)`), and run 35522642934 was dispatched to read
it; its result is the next correction.

## Correction, 2026-09-20: the package run, green on three operating systems
Supersedes the previous correction's last sentence. Run 35522642934 printed the macOS and Windows failure at
last: the data-directory lock refusing the launch after the smoke run (NOTES.md finding 16, `fix(s010)`). Run
**35523664194**, on the tree with that fix: **linux x86_64, macOS aarch64 and windows x86_64 all green**,
`TRINITY_SMOKE_MARKDOWN=ok` on each (the NIF built from source for musl on Linux, precompiled on the other two),
`HTTP 200` from the packaged binary in 1,526 ms, 1,680 ms and 1,761 ms from launch. R24's lift condition is met.
The final commit and the pull request are named in the closing correction.

## Closing correction, 2026-09-20
Supersedes the closing correction above it: the branch grew past `8cc90b7` while the package workflow was
brought green (commits `68c00a6` to `ff2b316`, listed by `git log --oneline main..HEAD` on pull request #24). The
ROADMAP row stays `done`; the pull request is #24; the merge commit and the tag come after the owner's review.
