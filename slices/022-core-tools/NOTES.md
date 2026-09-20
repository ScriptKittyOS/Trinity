# Slice 022: NOTES

## Two decisions the spec asks for before the slice, taken at G1 (open to the owner's veto)

**The Windows shell.** MuonTrap 2.0.0 (hex, 2026-08-13) is a C port wrapper built with `elixir_make`: `fork`,
`exec`, SIGTERM then SIGKILL after `:delay_to_sigkill`, optional cgroup v2 limits (read from its tarball in a
scratch directory, `lib/muontrap.ex` and `c_src/muontrap.c`). It does not build on Windows, and the guarantee
docs/02 chose it for (the child dies when the Task dies) has no Windows implementation in the tree. Decision:
**the shell tool is POSIX-only at this slice.** `muontrap` is declared in `mix.exs` only where `:os.type/0` is
`:unix` (the same shape as `postgrex` behind `TRINITY_DB`), the shell tool answers `available?/0` false on
Windows and the registry skips it with a logged reason, docs/07 states the guarantee per platform, and the
approval card says which applies. A Windows runtime (job objects) is a later slice's measurement, named in
the follow-ups; a `System.cmd` fallback that can orphan a process is not offered.

**The search provider.** Brave Search API: one JSON request, a key in `BRAVE_SEARCH_API_KEY`, results as
title, url, description. The alternatives: Tavily and Exa are LLM-oriented and return page content (more
to redact, more to wrap); DuckDuckGo-HTML is a scrape of a page that changes. `Trinity.Tools.Web.SearchProvider`
is the behaviour; `Brave` its one implementation; `Fake` for tests; the live test is tagged and manual (AC6).

## G1 plan, 2026-09-20

Tree at `808897b` on `main` (021 approved); branch `slice/022-core-tools`; ROADMAP row 022 to `in_progress` in
this commit. Each line names its test.

1. `chore(s022)`: `floki ~> 0.38` and `muontrap ~> 2.0` (POSIX only in `deps/0`); VERSIONS rows.
2. `Trinity.Content.Part` (`origin`, `source_ref`, `digest`, `taint`, `text`; `max_taint/1`) and
   `Trinity.Tools.Untrusted.wrap/2` (a Part tainted `untrusted` with a SHA-256 digest); `Result` carries
   `parts`; the tool row stores them (`parts.content_parts`, `parts.taint`); the Session tracks the turn's
   maximum taint and writes it on the assistant row; `Prompt` renders a tainted tool row inside
   `<untrusted source= digest=>` and the system prompt states the rule. Tests (AC11): a summary turn over an
   untrusted page carries `taint: untrusted`; an instruction inside the page is rendered inside the wrapper
   and nowhere else in the request.
3. The escalation hook: `Tool.escalate/2` (optional; args and context to a tier, or `:ask`, or nil) may only
   raise a call's tier; the runner passes it as `escalate:` and `Policy.Layered` takes the higher of the name's
   tier and it. Test: an escalation raises `read` to `ask`; an escalation can never lower.
4. `Trinity.Tools.FS`: roots from `config :trinity, :fs, roots:` plus the session's cwd; `resolve/2`
   normalises, follows symlinks, and answers `{:ok, path} | {:error, :outside_roots}`; `backup/1` (a ring of
   five per file under `<data dir>/backups/<sha256 of path>/`), `restore/2`; the write-validation hook
   (`Trinity.Tools.FS.Placeholders.find/1`: `/* ... */`, `// ... rest`, `# ... rest unchanged` and kin). Tools
   `FS.Read` (lines with offset and limit, a size cap), `FS.Write` (atomic temp and rename, backup first,
   `allow_placeholders` escalates to `:destructive`), `FS.Edit` (unique search, replace, a unified diff in the
   result), `FS.List`, `FS.Glob`, `FS.Grep` (regex, file and match caps). Every read outside the roots escalates
   to `:ask`. Tests: AC1 to AC4 and each tool's shape.
5. `Trinity.Tools.Web.Fetch` (Req; timeout 20 s; 1 MB cap; `text/html` through Floki with script, style, nav,
   header, footer, aside removed and the body's text taken; `text/*` raw; anything else a descriptive error;
   the result an untrusted Part) and `Web.Search` over the provider. Tests: AC5 against a Bandit test server on
   the loopback (`Trinity.NetworkGuard` allows loopback), AC6's fake half.
6. `Trinity.Tools.Shell.Run` (POSIX): `MuonTrap.cmd("/bin/sh", ["-c", cmd], cd:, env:, timeout:)`, the cwd
   inside the roots, the environment scrubbed to `PATH`, `HOME`, `LANG`, `TERM` and `TMPDIR`, timeout 120 s by
   default and capped, output 1 MB with the head and the tail kept, risk `:exec`, `Shell.Dangerous.match/1`
   (a pattern list: `rm -rf /`, `curl … | sh`, `sudo`, `chmod 777`, `mkfs`, `dd of=/dev`, `> /dev/sd`, fork
   bombs, `git push --force`) escalating to `:destructive`; `available?/0`. Tests: AC7 (`sleep 10` at 1 s:
   killed, `ps` shows no `sleep`), AC8 (Mox policy sees `escalate: :destructive`), AC9 (`env` prints no secret).
7. Toolsets `:fs`, `:web`, `:shell` and the core modules in `config/config.exs` (dev and prod); the test config
   adds them beside the test tools. `Permissions.tier/1` now answers for real names.
8. docs/07 (shell per platform, filesystem as built), docs/01 (the tools tree), docs/03 (toolsets), VERSIONS.
9. AC10: the end-to-end run recorded here with the chromium driver (playwright's video, converted to a GIF with
   the ffmpeg in its cache) on the test registry with the fake provider scripting the calls; the owner's own
   run is the manual queue.
10. Gate, coverage row, PROOF.md, ROADMAP to `done`, pull request (signed merge body), tag.

Manual verification queue, for the owner at G4:
- **AC6**: `BRAVE_SEARCH_API_KEY=… TRINITY_LIVE=1 mix test --only live test/trinity/tools/web/search_live_test.exs`:
  the real provider answers with titles and urls; the test prints counts and hosts, never the key or the
  descriptions.
- **AC10**: `scripts/dev_chat_on_test_registry.sh` (or the fake flag in dev) and "list the files in the project
  and summarise the README": a `fs_list` call runs without asking, a `fs_read` of README.md runs, the summary
  arrives; a write asks. GIF in `proof/`.

Deviations from SLICE.md, stated before building: tool names are the flat `fs_read`, `fs_write`, `fs_edit`,
`fs_list`, `fs_glob`, `fs_grep`, `web_fetch`, `web_search`, `shell` (the tier is a function of the name; a dotted
or namespaced core name would read as dynamic); `<untrusted>` wrapping is the Part's rendering, not a string
the tool returns (the M1 alignment says so); the search provider is Brave unless the owner names another;
the shell is POSIX-only (above); `Web.Fetch` does no JavaScript and says so in its description.
