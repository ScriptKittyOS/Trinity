# Slice 013: NOTES

## The renderer, measured 2026-09-20 before any code

SLICE.md names `phoenix_streamdown` as the first candidate and `earmark` or `mdex` as the fallback, and asks
for the measurement. Packages read from their Hex tarballs in a scratch directory, never added to the tree
(`mix hex.package fetch <name> <version> --unpack`); the hex.pm API read with `curl -s
https://hex.pm/api/packages/<name>`.

| Candidate | Result | Derived by |
|---|---|---|
| `phoenix_streamdown` 1.0.0-beta.4 | Still the latest release, dated 2026-05-03; `latest_stable_version` is null. 801 lines in four files. It depends on `mdex ~> 0.11` and does two things over it: completes unclosed markdown syntax per token (its `Remend` module) and splits the text into blocks so finished blocks sit under `phx-update="ignore"`. VERSIONS.md forbids a pre-release, and the owner has not accepted one. | the API's `releases[0]`; `find lib -name '*.ex' \| xargs cat \| wc -l`; `grep '{:' mix.exs` |
| `earmark` 1.4.49 | **Retired on hex** (`retirement.reason: deprecated`, "Earmark is no longer maintained. Migrate to a replacement, for example MDEx") **and carries an open advisory**, EEF-CVE-2026-48591 (medium, stored XSS via unescaped HTML attribute values). Both gate steps refuse it: `mix hex.audit` prints "Found retired packages" and `mix deps.audit` the advisory. Not a candidate. | `mix hex.audit` in the scratch project, exit 0 with both findings printed; the API's `releases/1.4.49` `retirement` field |
| `mdex` 0.13.5 | Stable, released 2026-07-29, 1.4 M downloads. Its own `streaming: true` option completes fragments (`MDEx.FragmentParser`: `"Some **bold te"` renders `<strong>bold te</strong>`, an unclosed fence closes), which is the half of streamdown that matters; the other half is a design rule SLICE.md already states. With `render: [unsafe: false]` raw HTML is omitted and a `javascript:` href is emptied; the default sanitizer (ammonia) on top drops the omission comments and adds `rel="noopener noreferrer"`. Cost: 6,420 bytes of mixed markdown render in 5.6 ms, 642 bytes in 0.7 ms (100 runs each, `:timer.tc`), so twenty renders a second of a long in-progress message is a tenth of a core. | the scratch `bench.exs`, output kept below |
| `mdex_native` 0.2.8 (mdex's NIF) | A Rust NIF through `rustler_precompiled`: artifacts for eleven targets, among them the four the packaging chain builds for (x86_64 and aarch64 darwin, x86_64 and aarch64 linux-gnu, x86_64 windows msvc and gnu). This machine downloaded `libmdex_native_nif-v0.2.8-nif-2.15-x86_64-unknown-linux-gnu.so` at compile and `mix hex.audit` reports nothing on the set. Slice 001 proved the packaging chain with a pure-BEAM release; a NIF is new to it. | `mix compile` in the scratch project (the download line is in its log); `checksum-Elixir.MDExNative.Native.exs` in the package |

```
$ mix run bench.exs         (scratch project, mdex 0.13.5)
100 streaming renders of 6420 bytes: 563.142 ms total, 5.63142 ms each
100 streaming renders of 642 bytes: 70.593 ms total, 0.70593 ms each
```

**Decision at G1: `mdex ~> 0.13`, and no `phoenix_streamdown`.** `earmark` is refused by the gate. The
pre-release stays unpinned as VERSIONS.md requires; its two contributions are one `mdex` option and one rule this
slice keeps anyway (completed messages rendered once, the in-progress message as one assign replaced whole). The
NIF is the cost: the `package` workflow runs on the `mix.lock` change and builds on all three runner operating
systems, which is the first measurement of a NIF in the bundle, cited in PROOF.md by run id. Open to the owner's
veto at G1.

## Design language, decided at G1

SLICE.md decides the design language here and asks for tokens later slices consume. Dark by default with the
three-way toggle kept (system, light, dark), clean rounded panels, and a font stack the tokens name once:
`Ubuntu, Comfortaa, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`, with `"Ubuntu Mono", ui-monospace,
SFMono-Regular, Menlo, Consolas, monospace` for code. **No font file ships at this slice**: Ubuntu is under the
Ubuntu Font Licence 1.0 and Comfortaa under the OFL 1.1, and bundling either adds a licence file and a REUSE row
to a tree meant for donation; slice 100 decides what the packaged app carries once its target list is fixed, and
a web font is an egress this slice does not open (CLAUDE.md §8: every egress gets a redaction row). Until then a
machine without Ubuntu or Comfortaa installed falls through to its system font, which is what the stack is for.
Open to the owner's veto at G1: bundling Comfortaa (OFL 1.1) now is the alternative.

The tokens live in `assets/css/app.css` as two daisyUI themes (`trinity-dark`, default; `trinity-light`) and a
Tailwind `@theme` block (fonts, type scale, radius, spacing); `docs/03-conventions.md` gains a UI section naming
them and the component vocabulary (`TrinityWeb.ChatComponents`) later surfaces take.

## G1 plan, 2026-09-20

Tree at `835485c` on `main` (012 approved); branch `slice/013-liveview-chat-streaming`; ROADMAP row 013 set to
`in_progress` in this commit. Each line names its test; the order is the build order.

1. `chore(s013): add mdex ~> 0.13` as its own commit; `lib/trinity/versions.ex` gains the row and marks
   `phoenix_streamdown` not used, `mix versions.gen` rewrites VERSIONS.md. Test: the gate's audit steps.
2. `TrinityWeb.Markdown.to_html/2` (`streaming:` boolean): mdex with strikethrough, table, autolink and tasklist,
   `unsafe: false`, the default sanitizer. Test: raw HTML omitted; a `javascript:` href emptied; an unclosed fence
   completes when streaming; the same text renders the same HTML twice (pure).
3. Design tokens in `assets/css/app.css` (above), the root layout defaulting to dark, `docs/03` UI section.
   Test: `mix assets.build` exits 0 (CI builds no assets; the run is pasted in PROOF.md).
4. `Trinity.Sessions.default_persona/0` (the row named `default`, created on first use with no soul, so the
   prompt keeps its "You are Trinity." fallback; slice 030 seeds the SOUL into it), `Sessions.set_model/2`
   (writes `sessions.model`; refuses an id the registry does not know), and the Session re-reads its row at
   the start of every turn (one line in 012's `start_model_call`, so a model set between turns is the next
   turn's model). `Session.state/1` gains `text`, the in-progress draft, for a remount mid-stream. The fake
   provider records the last request it saw (`last_request/0`). Tests: set_model then a turn, the fake saw the
   new model (AC6's core); an unknown id refused; `state/1` shows the text mid-stream.
5. Router: `live_session :chat` with `/` (`SessionLive.Index`) and `/s/:id` (`SessionLive.Show`); the scaffold
   home page, its controller and its test go, the index is the home. `TrinityWeb.Plugs.ContentSecurityPolicy`
   on the browser pipeline: a per-request nonce, `script-src 'self' 'nonce-…'`, the inline theme script and the
   LiveDashboard carry it; the slice-000 sobelow skip that named this slice as the owner is retired. Test: `GET /`
   answers with the header and the inline script carries the same nonce.
6. `SessionLive.Index`: the session list (title or first user line, model, last activity), "New session" on
   the default persona, navigating to it. Test: a session is listed; "New session" creates a row and redirects.
7. `SessionLive.Show` mount: subscribe, `ensure_started/1`, history into a `:messages` stream, the state view
   into `@status` and `@draft`; delta messages already queued when the state reply arrives are drained, because
   the reply's text contains them (the Session sends both, in order). Events: `user_message`,
   `assistant_message` and `turn_interrupted` insert into the stream and clear the draft; `assistant_delta`
   appends to the draft assign; `state` sets the status; `tool_call` adds a running tool card; `error` sets the
   banner. Tests: AC2 (send, deltas, the final message once in the DOM), AC5 (remount mid-stream: the draft so
   far, then the final message, no duplicate, no gap), AC4's test half (`Process.exit(session, :kill)`: the
   banner appears, the next message works).
8. `TrinityWeb.ChatComponents`: `message` (role, time, usage badge, markdown), `tool_card` (name, args summary,
   status, expandable result), `composer` (textarea; Enter sends, Shift+Enter a newline, through a colocated
   hook; disabled unless idle), `model_picker` (`Trinity.LLM.models/0`), `cancel_button`, `interrupted_banner`
   with Retry (re-sends the last user message), `status_pill`. Tests: AC3's test half (cancel: the banner and the
   interrupted message), AC6 (the picker changes `sessions.model`).
9. Keyboard: a `Shortcuts` hook on the window (`Ctrl/Cmd+K` new session, `Esc` cancel) pushing two events the
   LiveView already handles; no other key reaches the server. Test: the two events, driven directly.
10. AC7: a test attaches to `[:phoenix, :live_view, :render, :stop]` for the Show process, streams 1,000 deltas
    and asserts at most 25 renders with the text intact; the count is recorded in PROOF.md.
11. The fake provider in dev: `Trinity.LLM.Providers.Fake` moves from `test/support` to `lib/trinity/llm/providers`
    (it is the scripted provider, and the dev registry needs it); `TRINITY_FAKE_PROVIDER=1` in `config/runtime.exs`
    replaces the dev registry with the fake and gives it a markdown demo script with short sleeps. Tests unchanged.
12. `mix sobelow --exit --skip` with no new finding; the CSP skip retired, the reasons file rekeyed if a line moved.
13. docs/01 (the web layer at 013: the two LiveViews, the subscribe path); docs/06 gains the NIF-in-the-bundle risk
    row with its lift condition (the `package` run green on three operating systems).
14. Screenshots under `proof/` from the running app with the fake provider, taken here where a browser exists;
    the real-provider run is the owner's.
15. Gate, coverage row, PROOF.md, ROADMAP to `done`, pull request, tag.

Manual verification queue, for the owner at G4:
- **AC1**: `TRINITY_FAKE_PROVIDER=1 mix phx.server`, open `/`, New session, send "hello", watch the markdown stream
  in; then the same with a real provider (`set -a; . ./.env; set +a; mix phx.server`). Screenshot or GIF.
- **AC3**: send a message with the fake's demo script (it streams for a few seconds), press Cancel or Esc mid-stream:
  the partial text stays, marked interrupted, with the banner and Retry. Screenshot.
- **AC4**: with the page open mid-stream, in `iex -S mix phx.server`: `Process.exit(Trinity.Sessions.whereis(id), :kill)`.
  The banner appears without a reload; the next message works. Screenshot.

Deviations from SLICE.md, stated before building: the renderer is `mdex`, not `phoenix_streamdown` (measured
above). The fake provider moves into `lib/` so dev can run it (the slice asks for a dev config flag, which needs the
module compiled in dev). Two small changes land in 012's modules (`start_model_call` re-reads the row; `state/1`
carries the draft text), each a `fix(s012)`-style line inside this slice's commits, because AC5 and AC6 cannot be
met without them. The CSP arrives here because the slice-000 skip named 013 as its owner.

## Lines 1 to 14, 2026-09-20: what was built, and what building it found

**Built.** `mdex ~> 0.13` (its own commit); `TrinityWeb.Markdown` (one `to_html/2`, the tree's only `raw/1`);
the tokens in `assets/css/app.css` (two daisyUI themes, dark the default, a `@theme` block for fonts, the two
chat text sizes and the radii) with the UI section in docs/03; `TrinityWeb.ChatComponents` (`message`,
`tool_card`, `draft`, `composer`, `model_picker`, `status_pill`, `banner`, `local_time`); `Layouts.app` as the
shell (top bar with the brand, a `:bar` slot, the theme toggle); `SessionLive.Index` and `SessionLive.Show`;
four hooks in `assets/js/hooks.js`; `TrinityWeb.Plugs.ContentSecurityPolicy`; `Sessions.default_persona/0`,
`set_model/2`, `set_title/2`; `Session.state/1` with `text`; the Session re-reading its row per turn; the fake
provider in `lib/` with `last_request/0`, a `:demo` script and the `TRINITY_FAKE_PROVIDER=1` flag.

**Found while building, each recorded rather than smoothed.**

1. **`earmark` is refused by the gate, not just unattractive.** The measurement meant to compare render cost
   found the package retired on hex with an open XSS advisory before a line of it ran (`mix hex.audit` in the
   scratch project). SLICE.md's fallback pair was really one candidate.
2. **A stream container cannot hold the in-progress message.** The draft sat in a sibling below the
   `phx-update="stream"` list, which put it at the bottom of the viewport with a gap above it in the first
   screenshot. One scroll region now wraps the stream container and the draft.
3. **The formatter reflowed a `whitespace-pre-wrap` element** across three lines, and the newline rendered as a
   blank line above every user message; caught in a screenshot, fixed with `phx-no-format` (its own commit).
4. **Tool rows have no event.** 012 broadcasts `tool_call` at the start of a call and nothing when the row is
   written, so a page would never show a tool result until a reload. The page reads the rows past its last seen
   `seq` on every final or interrupted message; no new event shape, so `Events` is untouched.
5. **A new incarnation says idle before it says interrupted.** With `state_enter`, the enter broadcast for `idle`
   precedes the internal rehydrate event, so a test waiting for `turn_interrupted` and then `state idle` waited
   five seconds for a message that had already passed. The kill test waits for the second only.
6. **The Show page's status pill and the draft's pill shared an id**, which LiveViewTest refuses (duplicate id);
   the component takes an `id` now.
7. **sobelow does not see a policy set by a plug.** It recognises only a header map given to
   `put_secure_browser_headers`, so the CSP finding stays reported with the plug in place; the skip is rekeyed
   (the plug moved the pipeline's line) with the reason naming the test that asserts the header.
8. **`@sobelow_skip` on a function is an unused attribute to the compiler**, which `--warnings-as-errors` turns
   into a gate failure; `Trinity.Paths` had met the same at 001 and registers the attribute as persisted, and
   `TrinityWeb.Markdown` does the same.
9. **The dev database was behind on migrations** (011's `usage_events`), so the first `mix phx.server` answered
   503 with `PendingMigrationError`; `mix ecto.migrate` and a restart.
10. **One uncaptured failure in eleven runs** of `mix test test/trinity_web` (the run right after commit
    `e33f5bc`: 20/21, the failing test's name lost to a `tail`); ten later runs of the same directory and six
    of `test/trinity_web/live` alone were green, the gate run was green. Recorded so a recurrence in CI has a
    place to land; the output goes here when it does.

**Deviations from SLICE.md**, in addition to the four stated at G1: the screenshots for AC1, AC3 and AC4 were
taken here, from the dev server driven by a headless chromium (`playwright-core` in a scratch directory, the
browser from the machine's playwright cache), rather than left entirely to the owner; the manual queue stands,
and the owner's own run is the one that counts. `Ctrl/Cmd+K` and `Esc` reach the server as two pushed events
from one hook rather than `phx-window-keydown` bindings, so ordinary typing never round-trips. The `LocalTime`
hook rewrites server-rendered UTC times in the viewer's zone, which the slice did not ask for and a desktop app
cannot do without.

```
$ mix test test/trinity_web              → 21 passed (markdown, csp, index, AC2 to AC7)
$ mix gate                               → exit 0; 176 passed, 10 excluded; plan_check: PASS
$ mix test --cover                       → 64.50% total (Show 81.58%, Index 91.67%, ChatComponents 67.74%, Markdown 80.00%, CSP 100%)
$ mix credo --strict --all               → 596 mods/funs, found no issues
$ mix sobelow --exit --skip              → exit 0, no finding
```

## Follow-ups
- Slice 100 decides the font the packaged app ships (Ubuntu under UFL 1.0 or Comfortaa under OFL 1.1, each with
  its licence file and REUSE row); until then the stack falls through to the system font.
- The `package` workflow run on this branch's `mix.lock` change is the first proof of a NIF in the bundle (R24);
  100's cross-target build re-proves it per target.
- A tool result has no event of its own (finding 4); 020 may add one to `Events` when tools are real, or keep the
  catch-up read, which costs one query per final message.
- Syntax highlighting in code blocks: `mdex_native` ships a `lumis` variant; not taken here (a larger artifact for
  a nicety), open for 022 when tool output makes code blocks common.
- `CoreComponents` is the generator's file at 17% coverage; the chat does not use its `input`, `table` or `list`.
  A later slice that needs them styles them with the tokens or removes them.

## Corrections, 2026-09-20, after the gate on the final tree

11. **The gate refused the inline sobelow skip once its file was tracked.** `test/sobelow_skips_test.exs` reads
    `git ls-files`, so the first green gate (markdown.ex untracked) could not see the `@sobelow_skip` whose
    comment block said the reason without the `# sobelow_skip reason:` marker the enforcer looks for. Fixed in
    `080c543`; distinct from finding 10, whose one failure was in `test/trinity_web` and stays uncaptured.

Supersedes the coverage line in the block above: `mix test --cover` on the final code tree (`080c543`) reports
**64.41%** total, the value `coverage.tsv` carries; 64.50% was the tree two commits earlier.

## The package workflow, 2026-09-20, after the pull request opened

The `package` workflow did not fire on the push (its `paths` filter did not match a new branch), so it was
dispatched by hand: run 35518054546, then 35519205973 with the serve step taught to print `serve.log` on any
non-200 (a `fix(s001)` line: the first run printed "HTTP 500" and nothing else). Three findings, each
reproduced here on a fresh install of the locally built linux binary (`rm -rf ~/.local/share/.burrito`, a fresh
`DATABASE_PATH`), which is the only kind of local run that means anything: Burrito reuses an extracted payload
keyed by name and version, so the first local run of the new binary executed the payload from 2026-09-06 and
answered 200 for the old home page.

12. **The packaged binary never ran a migration** (`fix(s010)`, commit `1f677b0`). `skip_migrations?/0` keyed on
    `RELEASE_NAME`, which `bin/desktop` exports and the Burrito wrapper does not (it starts `erlexec` directly),
    so every table was missing and `/`, the first page to read one, answered 500 on all three operating
    systems. Now "skip under Mix". Measured after: four migrations logged, `/` 200 three times.
13. **The mdex NIF does not load in the Linux bundle.** Burrito's Linux ERTS is a musl build (`make_triplet/1`
    appends `-musl`; `beam.smp`'s interpreter is a musl libc), and both precompiled artifacts fail in it: the
    gnu one and the musl one (`TARGET_ABI=musl`) each NEED `libgcc_s.so.1`, which resolves to the host's glibc
    copy and dies on `_dl_find_object: symbol not found`. `TrinityWeb.Markdown` then falls back to escaped text,
    so the chat works but shows `**bold**` literally (the screenshot from that run is kept out of `proof/`).
    R24 fired; its lift condition is not met by the precompiled route.
14. **A source build for musl with Zig as the linker loads and renders.** `rustup target add
    x86_64-unknown-linux-musl`, then `cargo build --release --target x86_64-unknown-linux-musl
    --no-default-features --features nif_version_2_15` with `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER` set
    to a two-line `zig cc -target x86_64-linux-musl` wrapper (Zig 0.16.0 is already pinned for Burrito): 23 s,
    NEEDED `libc.so` only, the same shape as the exqlite NIF Burrito itself cross-compiles. Swapped into the
    extracted payload, the packaged chat renders the real provider's answer as markdown, no `on_load` warning
    (screenshot `proof/ac1-final-openrouter-packaged.png`). Rust's own self-contained musl linking refused
    (`unable to find library -lgcc_s`), and the crate's `.cargo/config.toml` turns `crt-static` off for musl.

**Open decision for the owner, before this slice closes.** Two ways to a packaged Linux binary that renders:
(a) keep `mdex` and build its NIF from source in the linux packaging job: `rustler` joins the tree as a
build-time dependency, the job installs the musl Rust target and links through Zig, `MDEX_NATIVE_BUILD=1` and
`config :mdex_native, MDExNative.Native, target: "x86_64-unknown-linux-musl"` for that build only; macOS and
Windows keep the precompiled artifacts, unproven there because the `package` workflow has failed at "Serves
HTTP 200" on both since the slice/011 tag run (35512430836), before this slice, and now prints why; or (b) a
pure-Elixir renderer: `earmark_parser` 1.4.46 (the AST half of earmark, not retired, no advisory as of today's
`hex.audit`) with Trinity's own HTML emitter and fragment completion, no NIF anywhere, the renderer's
measurement redone. My recommendation is (a): the measurement above is the proof, the cost is one build-time
dependency and thirty seconds of the linux job, and (b) rewrites the renderer against a parser whose author
retired its sibling. Until the owner decides, the pull request stays open with the migration fix on it; the
required checks (`gate`, `postgres`) are green on every commit.

## The decision, 2026-09-20: (a), keep mdex and build its NIF for musl

Owner's words: "go with a and continue". Built in one commit: `rustler ~> 0.38` at build time; the three
compile-time settings in `config/config.exs` (`MDEX_NATIVE_BUILD=1`, `TRINITY_NIF_TARGET`, the Zig linker
`scripts/zig-cc-musl`), set by the package workflow's linux job alone; the musl target named in
`rust-toolchain.toml`; `Trinity.Smoke` printing `TRINITY_SMOKE_MARKDOWN=ok` (exit 3 otherwise) and the
workflow's smoke step reading it on every target; `TrinityWeb.Markdown` logging once at `:error` on a fallback.

15. **The smoke Task lost a race it had always been winning.** Rendering one line inside the Task before the
    halt took long enough for `Kernel.CLI` to reach the plain argument `--smoke` and treat it as a file ("No
    file named --smoke", exit 1). The render now happens inside `Application.start/2`, in `children/1`, and the
    Task prints and halts at once as before. Three fresh-install smoke runs: `ok`, exit 0; with the gnu artifact
    swapped into the payload: `failed:%MDEx.DecodeError{}`, exit 3.

16. **The macOS and Windows serve failures were the data-directory lock.** Run 35522642934 printed the reason
    the older runs had hidden: "is held by OS pid ... in desktop mode; refusing to start" on the launch after
    the smoke run. Slice 010 read liveness on Linux alone and treated any file as held elsewhere, and the smoke
    path halts without `terminate/2`, so the file it left refused every second launch on both platforms. Tried
    first: `System.stop/1` in the smoke path so the lock's terminate runs; it is asynchronous, and `Kernel.CLI`'s
    "No file named --smoke" (finding 15) won two runs in three. Kept: `System.halt/1` as slice 001 had it, and
    liveness read through `kill -0` and `tasklist` (`fix(s010)`, the commit before this record). Run **35523664194**: green
    on all three operating systems, `TRINITY_SMOKE_MARKDOWN=ok` on each, HTTP 200 in 1,526 ms (linux),
    1,680 ms (macOS) and 1,761 ms (windows) from launch. The first green `package` run since the slice/011 tag.

## After approval, 2026-09-20

17. **The merge commit of this slice is unsigned, and it is under a protected tag.** `gh pr merge --merge
    --subject ...` with no `--body` let GitHub write the message; the slice/012 merge had carried the
    sign-off in its `--body`. plan_check rule 8 reads the whole history, so every gate failed from that commit
    on, and `main` cannot be rewritten. Resolution, in the open: rule 8 names `3db7a5ff…` as its one exemption
    with this reason, docs/03 gains the rule that a merge commit's body carries the sign-off, and the next
    merge is checked with `git log -1 --format=%B` before the tag. The mistake is mine and the record stays.
