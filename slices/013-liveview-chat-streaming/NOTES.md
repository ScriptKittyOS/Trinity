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
