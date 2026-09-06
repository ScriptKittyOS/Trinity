# PROOF — Slice NNN — <Title>

Agent: <model/version> · Date: YYYY-MM-DD · Branch: slice/NNN-… · Final commit: <sha>

## Summary (3–6 lines)
What was built, what was hard, what was deferred (link NOTES.md follow-ups).

## Gate
```
$ mix gate
<trimmed output — must end in success>
```

## Tests
```
$ mix test --cover
<summary lines: N tests, 0 failures; coverage %>
```

## Acceptance criteria evidence

### AC1 — <text of criterion>
```
$ <command>
<output>
```
Notes: …

### AC2 — …

## Manual verification for the reviewer (if anything cannot be proven in CI)
Steps the human should run, expected result.

## Deviations from SLICE.md
None / see NOTES.md §Deviations.

## Versions touched
`VERSIONS.md` updated: yes/no. `mix hex.outdated` summary if run.

## Git
```
$ git log --oneline main..HEAD
```
