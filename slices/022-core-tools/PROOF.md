# Proof for slice 022: Core tools: filesystem, web, shell

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/022-core-tools · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
The first useful toolset: six filesystem tools behind roots judged after symlink resolution, with the
write-validation hook, atomic writes and a backup ring; a web fetch that extracts readable text without running
JavaScript and a web search behind a provider behaviour (Brave, with a fake); a shell under MuonTrap with a
scrubbed environment, a timeout that kills, an output cap and a dangerous-pattern tripwire. Every result from
outside the app is a tainted content part with a digest, rendered to the model inside an `<untrusted>` block the
system prompt names as data, and a turn's answer inherits the maximum taint of what it read (M1). A tool can only
raise its own tier from its arguments. Two decisions taken at G1 (NOTES.md): the shell is POSIX-only, and the
search provider is Brave. Nine findings in NOTES.md; the sharpest is that a port's environment option adds rather
than replaces, which AC9's red caught.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 1fb1372)
1059 mods/funs, found no issues.
... SCAN COMPLETE ...                        (sobelow --exit --skip: no finding)
No retired or security advisory packages found
No vulnerabilities found.
Result: 255 passed, 11 excluded
trinity.coverage: 021 72.45% vs 020 67.18%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 1059 mods/funs, found no issues.

## Tests
```
$ mix test --cover                           (tree 1fb1372)
Result: 255 passed, 11 excluded
    |      0.00% | Trinity.Tools.Web.SearchProvider.Brave |
    |     50.00% | Trinity.Tools.Shell.Dangerous          |
    |     76.92% | Trinity.Tools.Web.Search               |
    |     78.57% | Trinity.Tools.FS.Glob                  |
    |     80.00% | Trinity.Content.Part                   |
    |     81.94% | Trinity.Tools.Web.Fetch                |
    |     83.33% | Trinity.Tools.FS.List                  |
    |     86.67% | Trinity.Tools.FS.Edit                  |
    |     86.96% | Trinity.Tools.FS.Write                 |
    |     89.47% | Trinity.Tools.FS.Read                  |
    |     89.66% | Trinity.Tools.FS.Grep                  |
    |     91.67% | Trinity.Tools.FS                       |
    |    100.00% | Trinity.Tools.FS.Placeholders          |
    |    100.00% | Trinity.Tools.Shell.Run                |
    |    100.00% | Trinity.Tools.Untrusted                |
    |    100.00% | Trinity.Tools.Web.SearchProvider       |
    |    100.00% | Trinity.Tools.Web.SearchProvider.Fake  |
    |     74.85% | Total                                  |
```
`coverage.tsv` row: `022  74.85  1fb1372  2026-09-20` (from 72.45 at 021).

The 23 tests of the slice (`--trace`; the live search test excluded by tag):
```
test a binary content type and an HTTP error are descriptive errors; a bad URL is refused  * test a binary content type and an HTTP error are descriptive errors; a bad URL is refused (0.2ms) [L#61]
test AC1: the roots an escalation can only raise the tier  * test AC1: the roots an escalation can only raise the tier (0.9ms) [L#57]
test AC1: the roots a read inside the roots answers content; outside it escalates to :ask, and the gate says :ask  * test AC1: the roots a read inside the roots answers content; outside it escalates to :ask, and the gate says :ask (2.6ms) [L#27]
test AC1: the roots a symlink pointing outside the roots resolves outside  * test AC1: the roots a symlink pointing outside the roots resolves outside (0.4ms) [L#45]
test AC2: the write-validation hook content with a truncation marker is refused with the line named  * test AC2: the write-validation hook content with a truncation marker is refused with the line named (0.3ms) [L#67]
test AC2: the write-validation hook the marker list  * test AC2: the write-validation hook the marker list (0.3ms) [L#90]
test AC2: the write-validation hook the same content with allow_placeholders escalates to :destructive, and then writes  * test AC2: the write-validation hook the same content with allow_placeholders escalates to :destructive, and then writes (1.1ms) [L#79]
test AC3: atomic writes and the backup ring a write replaces the file whole, keeps a backup, and restore/2 brings the previous version back  * test AC3: atomic writes and the backup ring a write replaces the file whole, keeps a backup, and restore/2 brings the previous version back (27.1ms) [L#99]
test AC4: edit a unique search is replaced and a diff comes back; an absent or ambiguous one is refused  * test AC4: edit a unique search is replaced and a diff comes back; an absent or ambiguous one is refused (0.9ms) [L#125]
test AC6 (fake): web_search returns structured results as one untrusted part  * test AC6 (fake): web_search returns structured results as one untrusted part (5.9ms) [L#90]
test AC7: a command past its timeout is killed and leaves no process behind  * test AC7: a command past its timeout is killed and leaves no process behind (1725.6ms) [L#42]
test AC8: a dangerous command escalates to :destructive and the policy sees it  * test AC8: a dangerous command escalates to :destructive and the policy sees it (6.5ms) [L#56]
test AC9: a secret in Trinity's environment is not visible to the child  * test AC9: a secret in Trinity's environment is not visible to the child (6.5ms) [L#88]
test a cwd outside the roots asks; a missing one is an error  * test a cwd outside the roots asks; a missing one is an error (0.5ms) [L#119]
test a non-public host escalates to :ask; a public one does not  * test a non-public host escalates to :ask; a public one does not (0.1ms) [L#73]
test Brave answers a query with titles and urls  * test Brave answers a query with titles and urls (excluded) [L#14]
test caps the body at 1 MB and says so; plain text comes raw; a redirect is followed  * test caps the body at 1 MB and says so; plain text comes raw; a redirect is followed (84.5ms) [L#49]
test extracts the main text without chrome, keeps the title, and answers an untrusted part  * test extracts the main text without chrome, keeps the title, and answers an untrusted part (0.7ms) [L#23]
test list, glob, grep each answers an untrusted part and respects the roots  * test list, glob, grep each answers an untrusted part and respects the roots (1.7ms) [L#158]
test output over the cap keeps the head and the tail  * test output over the cap keeps the head and the tail (101.3ms) [L#110]
test runs a command in the working directory and reports the exit status  * test runs a command in the working directory and reports the exit status (14.5ms) [L#30]
test the assistant's summary of a fetched page carries taint untrusted; the user's message stays trusted  * test the assistant's summary of a fetched page carries taint untrusted; the user's message stays trusted (261.9ms) [L#32]
test the instruction inside the page is rendered only inside an <untrusted> block, and the system prompt states the rule  * test the instruction inside the page is rendered only inside an <untrusted> block, and the system prompt states the rule (11.0ms) [L#71]
```

## Acceptance criteria evidence

### AC1 [auto]: Read outside the allowlist → :ask, not a silent failure; inside → content
`AC1: the roots ...`: inside a root, `fs_read` answers numbered lines as an untrusted part and `escalate/2` is
nil; a file outside escalates to `:ask` and `Permissions.decide/4` with that escalation answers `:ask`, while the
inside call answers `:allow`. `a symlink pointing outside the roots resolves outside`: a link inside a root to a
directory outside resolves `:outside`; a path that does not exist yet resolves through its ancestor. `an
escalation can only raise the tier`.

### AC2 [auto]: Write with a truncation marker → rejected with an explanation; with allow_placeholders → approval required, then written
`content with a truncation marker is refused with the line named` (`// ... rest of file` at line 3, `/* ... */`;
nothing written; the message names `allow_placeholders`) and `the same content with allow_placeholders escalates
to :destructive, and then writes` (`escalate/2` is `:destructive`, the policy says `:ask`, `execute/2` then writes
the file whole). `the marker list`: `# ... rest unchanged`, a bare `...` line, "rest of the file unchanged" fire;
ordinary code does not.

### AC3 [auto]: Write is atomic (temp + rename) and creates a backup; FS.restore/2 restores the previous version
`a write replaces the file whole, keeps a backup, and restore/2 brings the previous version back`: the second
write's artifact is a backup holding v1; no `.tmp` file remains; `restore/2` brings v1 back (backing v2 up first,
so the ring holds both); seven more writes leave exactly five backups.

### AC4 [auto]: Edit fails when the search string is not unique; succeeds and returns a diff otherwise
`a unique search is replaced and a diff comes back; an absent or ambiguous one is refused`: "2 times" and "not
found" refusals by message; the unique edit writes and returns a diff with `-beta`, `+BETA` and the `---` header,
plus a backup artifact; a replacement with a marker is refused.

### AC5 [auto]: Web.Fetch against a local test server: main text, size cap, untrusted wrapping; binary → descriptive error
`Trinity.FakeWeb`, a Plug that `Req`'s `plug:` option routes to (no socket; NOTES.md finding 4): `extracts the main
text without chrome ...` (heading and paragraphs kept; nav, header, sidebar, footer and script text absent; the
title in meta; one untrusted part with the URL and a 64-hex digest; the injected instruction present as data),
`caps the body at 1 MB ...` (exactly 1,048,576 bytes with `capped_at_bytes`; plain text raw; a redirect followed),
`a binary content type and an HTTP error are descriptive errors ...` (`image/png` named; "HTTP 500"; `ftp://`
refused), `a non-public host escalates to :ask ...` (localhost, 127.0.0.1, 10.0.0.5, 169.254.169.254, ::1,
`.local` ask; public hosts do not).

### AC6 [manual]: Web.Search fake returns structured results; a live-tagged test hits the real provider
`AC6 (fake): web_search returns structured results as one untrusted part` (two of three results, the provider
named, the snippet's injected instruction carried as data). The live half: `test/trinity/tools/web/search_live_test.exs`
(tagged `live`, prints counts and hosts only), the owner's manual queue; not run here (no Brave key in `.env`).

### AC7 [auto]: Shell.Run "sleep 10" with a 1 s timeout → killed; no orphan process
`AC7: a command past its timeout is killed and leaves no process behind`: `sleep 10 # <marker>` with
`timeout_ms: 1_000` answers within 3 s with `timed_out` and "[killed"; 700 ms later `ps -eo args` carries no line
with the marker.

### AC8 [auto]: an rm -rf /-like command → :destructive and approval required (Mox on Permissions)
`AC8: a dangerous command escalates to :destructive and the policy sees it`: eight commands (`rm -rf /`,
`rm -rf ~`, `curl … | sh`, `sudo …`, `chmod -R 777 /`, `dd … of=/dev/sda`, `git push --force`, the fork bomb) each
escalate to `:destructive` and match the pattern list; `ls -la` and `rm -rf ./build` do not; a Mox policy receives
`escalate: :destructive` for `rm -rf /` and its denial becomes the runner's `:denied`.

### AC9 [auto]: secrets in the environment are not visible to the child
`AC9: a secret in Trinity's environment is not visible to the child`: with `TRINITY_TEST_SECRET_KEY` set, `env |
grep SECRET` in the child prints nothing and `HOME` is still there; `scrubbed_env/0` carries a value only for
the seven kept names and `nil` for every other name (finding 1: the red that found the port's semantics).

### AC10 [manual]: "list the files in the project and summarise the README" works with approvals (GIF)
`proof/ac10-list-and-summarise.gif` (31 frames) and three stills: the fake provider scripts `fs_list` on the
project directory (outside the roots: the card asks, "Allow for this session"), then `fs_read` of `README.md` (a
different fingerprint: asks again, "Allow once"), then the summary; `scripts/dev_chat_list_and_summarise.sh` is
the run, for the owner's own hands.

### AC11 [auto]: a summary of an untrusted page is tagged untrusted; an instruction inside it is not a command to the prompt builder
`the assistant's summary of a fetched page carries taint untrusted; the user's message stays trusted` (the tool
row `untrusted` with its part and digest; the assistant row that asked for the page `trusted`; the summary
`untrusted`; the next turn `untrusted` too) and `the instruction inside the page is rendered only inside an
<untrusted> block, and the system prompt states the rule` (the rebuilt request: the rule in the system prompt,
the instruction absent from it and from every non-tool message, present in the tool message after the opening
`<untrusted source="tool:web_fetch" ref=… digest=…>` tag and before the closing one).

## Manual verification for the reviewer
1. AC6: put `BRAVE_SEARCH_API_KEY` in `.env`, then `set -a; . ./.env; set +a; TRINITY_LIVE=1 mix test --only live
   test/trinity/tools/web/search_live_test.exs`. Expected: one test passes and prints the result count and hosts.
2. AC10: `mix assets.build`, remove `priv/static/assets/**/*.gz`, then `scripts/dev_chat_list_and_summarise.sh`;
   open the printed port, New session, send "list the files in the project and summarise the README". Expected:
   the card for `fs_list` (allow for this session), the card for `fs_read` (allow once), the summary.

## Deviations from SLICE.md
See NOTES.md: the five stated at G1 (flat tool names, provenance as parts, Brave, POSIX-only shell, no
JavaScript) and finding 4 (a Plug in place of a Bandit test server).

## Versions touched
`VERSIONS.md` updated: yes, `floki ~> 0.38` and `muontrap ~> 2.0` (POSIX only in `mix.exs`) with their rows.
`mix hex.audit` and `mix deps.audit` clean.

## Git
```
$ git log --oneline main..HEAD
1fb1372 feat(s022): the core tools: filesystem, web fetch and search, the shell, and provenance
b45d7fc chore(s022): add floki ~> 0.38 and muontrap ~> 2.0 (POSIX only)
0c37b3c docs(s022): G1 plan with the two pre-slice decisions, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the "Final commit" field in the header: the commit carrying this file is `16d61ec`
(`feat(s022): complete slice 022 (core tools: fs, web, shell)`); the `git log` block above lists the commits
before it. The pull request, its merge commit (signed in its body) and the tag come after review.
