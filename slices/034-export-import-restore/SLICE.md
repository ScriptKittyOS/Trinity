# Slice 034 — Export, import, restore

| Field | Value |
|---|---|
| Phase | 3 Memory |
| Milestone | M3 Remembers |
| Size | S |
| Depends on | 030, 031 |
| Status | see ROADMAP.md |

## Goal
A user can take their whole Trinity with them: export the data dir to one archive, import it on a fresh install,
and restore after a loss. At the end of this slice, losing the machine is a recoverable event rather than a total one.

## Why
Vision goal 1 is "never lose your work". Every mechanism behind it so far addresses **process** loss: supervised
sessions, rehydration from the DB, persistence before broadcast. None addresses disk loss, file corruption, or
moving to a new machine, which for a local-first agent holding years of sessions, memories and skills is the more
likely way work actually disappears. The tree has a per-file backup ring (022) and a pre-migration DB backup (101),
and neither is a user-facing path.

## Scope
**In:**
- `mix trinity.export` and a Settings action: one archive containing the database, `skills/`, `personas/`,
  receipts and the key registry, plus a manifest with a per-file digest and the schema version.
- `mix trinity.import`: restores into an empty data dir, refuses a non-empty one unless explicitly forced, and
  verifies every digest in the manifest before writing anything.
- Signing keys are **excluded by default** and exported only on an explicit flag, so an archive handed to someone
  else does not carry the ability to sign as you. The manifest records which choice was made.
- Schema-version check on import: a newer archive into an older binary refuses with a named reason rather than
  migrating backwards.
- `docs/backup.md`: what is in the archive, what is not, and the restore procedure.
**Out:**
- Continuous or scheduled backup, cloud destinations, multi-device sync. Those are their own slices if wanted.

## Design notes
- Skills and personas are canonical on the filesystem and indexed in the DB, so import restores files and then
  reindexes rather than trusting the exported index.
- The receipt chain must verify after a round trip; that is the sharpest test of whether the export is faithful.

## Deliverables
- `lib/mix/tasks/trinity.export.ex`, `lib/mix/tasks/trinity.import.ex`, `lib/trinity/archive/*`, Settings action,
  `docs/backup.md`, tests.

## Acceptance criteria
1. [auto] Export then import into an empty data dir reproduces sessions, messages, memories, skills and personas; a
   content digest over the restored tree matches the manifest.
2. [auto] The receipt chain verifies end to end after the round trip.
3. [auto] Import into a non-empty data dir refuses with a named reason; forced, it states what it replaced.
4. [auto] A tampered archive fails digest verification before anything is written.
5. [auto] Signing keys are absent from a default export and present only with the explicit flag; the manifest records which.
6. [auto] An archive from a newer schema refuses to import into an older binary with a named reason.

## Proof required
- For each criterion: the command and its output, or the test name and its result. A sentence is not proof.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–6 proven · [ ] `docs/backup.md` written · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s034): complete slice 034 — export, import, restore` · tag `slice/034`

## Risks / open questions
- Archive size once embeddings and model caches exist. Measure and decide what is excluded by default.
