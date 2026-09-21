# Proof for slice 059: MCP capability gap against beam_mcp, and the server seam probe

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/059-mcp-gap · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
beam_mcp 0.8.0 (its commit `cfa706b`) measured against the fifteen items of the 2026-07-28 checklist, each
row a path and line at that commit with the command that derived it (`FINDINGS.md`); the two conflicts stated
against 061, 060 and 062's lines; the `:server` seam probed on a throwaway branch of a local clone (five
changed lines, one census test's pinned list widened by two entries, the branch deleted); `beam_mcp ~> 0.8` in
the tree behind `Trinity.MCP`, the one boundary the compiler lets reach it. Nothing was built on the core and
nothing was sent to it; no ADR-0007 amendment is proposed (NOTES finding 5). Six findings in NOTES.md.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 53c9091 with this file, coverage.tsv and the probe diff uncommitted on top)
2146 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 103 locked packages, none disagreeing with 53 pins
Result: 454 passed, 18 excluded
plan_check: PASS
exit=0
```
CI: named in the closing correction.

## Tests
```
$ mix test --cover                           (tree 53c9091)
Result: 454 passed, 18 excluded
|     66.67% | Trinity.MCP                            |   (core_events/0 is a constant read by 090)
|     80.54% | Total                                  |
```
`coverage.tsv` row: `059  80.54  53c9091  2026-09-21` (from 80.55 at 041: one hundredth, the boundary's
constant).

The slice's six tests (`mix test test/trinity/mcp --trace`):
```
test/trinity/mcp/boundary_test.exs
  * test beam_mcp is in mix.lock at 0.8.0 and the VERSIONS row reads in mix.lock
  * test the boundary compiler checks calls into beam_mcp everywhere, and Trinity.MCP is the boundary that lists it
  * test the planted reference is a real reference: the file the proof compiles names BeamMCP outside Trinity.MCP
test/trinity/mcp/findings_test.exs
  * test AC1: fifteen rows, numbered 1 to 15, each naming the pinned commit's paths with a line and a deriving command
  * test AC2: the two conflicts are stated against the slice lines
  * test AC3: the probe reports its diff size and the one census test it touches, and none of it is here
```

## Acceptance criteria evidence

### AC1 [auto]: `FINDINGS.md` carries one row per checklist item, each with a path and line at the pinned beam_mcp commit and the command that derived it
`FINDINGS.md`, rows 1 to 15; the pinned commit derived by `git rev-parse --short 'v0.8.0^{commit}'` → `cfa706b`
on the clone. `findings_test.exs` "AC1" parses the table and holds every row to a path with a line, a status
word and a deriving command. The population the rows read: `find lib -name '*.ex' | wc -l` → 25;
`wc -l docs/public-api.txt` → 142. The baseline suite at the pinned commit on its own toolchain:
```
$ cd <clone> && mix test                     (Erlang 28.1.1, Elixir 1.18.4-otp-28, .tool-versions of the clone)
11 properties, 705 tests, 0 failures
```

### AC2 [auto]: The two conflicts are stated against slice lines
`FINDINGS.md` "The two conflicts": A, will-not-implement entry 12 (no MRTR) against 061's `input_required`
criteria (`slices/061-*/SLICE.md:13-15,38`, which already carry the blocker); B, entries 9 (no client) and 8
(no OAuth) against 060's thin driver (`slices/060-*/SLICE.md:14-15`) and 062's roles. `findings_test.exs` "AC2".

### AC3 [auto]: The seam probe reports the diff size and the census tests it touches, with output; no code from it is merged anywhere
On the clone, branch `probe/server-option` from `cfa706b`:
```
$ git diff --stat
 lib/beam_mcp/transport/http.ex | 5 +++--
 1 file changed, 3 insertions(+), 2 deletions(-)
```
The diff is `proof/probe-server-option.diff` (a record, not a patch to apply: SLICE.md's "Out"). Before, at
`cfa706b`, and on the probe:
```
$ mix test test/beam_mcp/boundary test/beam_mcp/transport     (cfa706b)
180 tests, 0 failures
$ mix test test/beam_mcp/boundary test/beam_mcp/transport     (probe)
180 tests, 1 failure
  1) test the catalog is called through three callees: capabilities/0 at five sites, read_resource/1 at one, get_prompt/2 at one (BeamMCP.Boundary.NoCatalogTest)
     test/beam_mcp/boundary/no_catalog_test.exs:102
     calls through a variable module:
       ...
       {{BeamMCP.Transport.HTTP, :do_dispatch, 3}, :handle_message, 2}
       {{BeamMCP.Transport.HTTP, :do_dispatch, 3}, :new, 1}
$ mix test                                                     (probe, the whole suite)
11 properties, 705 tests, 1 failure
$ git checkout -- . && git checkout 'v0.8.0^{commit}' && git branch -D probe/server-option
Deleted branch probe/server-option (was cfa706b).
```
`findings_test.exs` "AC3": the report names the numbers and the test; `lib/beam_mcp` does not exist in this
tree and `mix.exs` fetches `beam_mcp` from hex, not a path or a git source.

### AC4 [auto]: `beam_mcp` is in `mix.lock`, its `VERSIONS.md` row reads in `mix.lock`, and `mix compile --warnings-as-errors` fails on a planted `BeamMCP` import outside `Trinity.MCP`
`boundary_test.exs`: the lock holds `{:hex, :beam_mcp, "0.8.0", …}`, the VERSIONS row reads `✅ in mix.lock`
(`mix versions.gen` flipped it), `Trinity.MCP.core_version/0` is `"0.8.0"`, mix.exs carries
`boundary: [default: [check: [apps: [:beam_mcp]]]]`, and the census over `git ls-files lib/*.ex` finds
`BeamMCP.` in `lib/trinity/mcp.ex` alone. The planted reference (its text kept at
`test/support/mcp/planted_reference.ex.txt`, which the test holds to be a real reference), compiled by the
command:
```
$ cat > lib/trinity/planted_beam_mcp.ex <<'EOF'
defmodule Trinity.PlantedBeamMcp do
  @moduledoc false
  def depth, do: BeamMCP.JSON.max_depth()
end
EOF
$ mix compile --warnings-as-errors
Compiling 1 file (.ex)
Generated trinity app
warning: forbidden reference to BeamMCP.JSON
  (references from Trinity to BeamMCP.JSON are not allowed)
  lib/trinity/planted_beam_mcp.ex:3
exit=1
$ rm lib/trinity/planted_beam_mcp.ex
```
Why the refusal is pasted and not a test: NOTES, the deviation stated before code.

### AC5 [auto]: Gate green; coverage line reported
The gate above; the coverage row `059  80.54  53c9091  2026-09-21`.

## Manual verification for the reviewer
None: every criterion is automatic. The reviewer may read `FINDINGS.md` beside the clone at `cfa706b`; every
row's last column is the command to rerun.

## Deviations from SLICE.md
NOTES.md, one stated before code (AC4's refusal pasted from the compiler, the test holding what makes it) and
one found building (`Trinity.MCP` is a top-level boundary, finding 1).

## Versions touched
`VERSIONS.md` updated: yes, by `mix versions.gen`: the `beam_mcp` row from 🔍 to ✅ in `mix.lock` (0.8.0).
`mix versions.verify`: OK, 103 locked packages, none disagreeing with 53 pins.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```

## Closing correction, 2026-09-21

Supersedes "named in the closing correction" above. The tree the PR is merged from is `e82c170` (`feat(s059):
complete slice 059`, the commit carrying this file). On it, CI gate run 35643511487: `gate` success (454
passed, 18 excluded), `postgres` success (434 passed, 38 excluded), `fips-tag` and `fips` success (459 passed,
13 excluded; the six FIPS tests by name). The coverage row stays at `53c9091` (80.54%): `e82c170` differs from
it in this file, NOTES.md, ROADMAP.md, README.md, coverage.tsv and the probe diff's copy only.

```
$ git log --oneline main..HEAD
e82c170 feat(s059): complete slice 059 (MCP capability gap and seam probe)
53c9091 feat(s059): beam_mcp 0.8.0 measured against the 2026-07-28 checklist, the seam probed, the dependency behind the Trinity.MCP boundary
```
