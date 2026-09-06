#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# plan_check.sh — enforces the plan-consistency rules that were previously prose.
#
# Every rule below was a finding that closed on a hand check and stayed broken.
# Populations derive from `git ls-files`; nothing here is a hand list.
#
# Scope note for check 6: it validates references to PLAN artifacts only —
# docs/, docs/adr/, slices/, templates/ and the root records. Paths under
# lib/, test/, priv/, config/, .github/ and tauri/ are deliberately excluded:
# they name code this plan has not built yet, so their absence is expected and
# is not evidence of a dangling reference.
#
# Exit 0 = all checks pass. Exit 1 = at least one failure, each printed with its location.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

fail=0
report() { printf '%s\n' "$1"; fail=1; }
section() { printf '\n== %s ==\n' "$1"; }

slice_files=$(git ls-files 'slices/*/SLICE.md')
tracked=$(git ls-files)

# ---------------------------------------------------------------- 1 + 2
section "1. Acceptance criteria numbered contiguously from 1"
section_2_pending=""
for f in $slice_files; do
  nums=$(awk '/^## Acceptance criteria/{fl=1;next} /^## /{fl=0} fl && /^[0-9]+\./{n=$0; sub(/\..*/,"",n); print n}' "$f")
  count=$(printf '%s\n' "$nums" | grep -c . )
  expected=$(seq 1 "$count" 2>/dev/null)
  if [ "$(printf '%s' "$nums")" != "$(printf '%s' "$expected")" ]; then
    report "FAIL $f: criteria numbered [$(echo $nums)] expected [$(echo $expected)]"
  fi
  section_2_pending="$section_2_pending$f $count"$'\n'
done

section "2. Definition of Done range equals the criterion count"
while read -r f count; do
  [ -z "${f:-}" ] && continue
  dod=$(grep -oE 'AC1[–-][0-9]+' "$f" | head -1 | grep -oE '[0-9]+$')
  if [ -z "$dod" ]; then
    report "FAIL $f: Definition of Done states no AC1-N range"
  elif [ "$dod" != "$count" ]; then
    report "FAIL $f: $count criteria but Definition of Done says AC1-$dod"
  fi
done <<< "$section_2_pending"

# ---------------------------------------------------------------- 3
section "3. Manual verification queue section present"
for f in $slice_files; do
  grep -q '^## Manual verification queue' "$f" || report "FAIL $f: no '## Manual verification queue' section"
done

# ---------------------------------------------------------------- 4
section "4. ROADMAP size and status agree with SLICE.md"
while IFS='|' read -r _ id _ _ size _ status _; do
  id=$(echo "$id" | tr -d ' '); size=$(echo "$size" | tr -d ' '); status=$(echo "$status" | tr -d ' ')
  case "$id" in ''|ID|*[!0-9]*) continue ;; esac
  sf=$(git ls-files "slices/$id-*/SLICE.md")
  if [ -z "$sf" ]; then
    [ "$status" = "withdrawn" ] || report "FAIL ROADMAP id $id: no slices/$id-*/SLICE.md and status is '$status' (only 'withdrawn' may lack one)"
    continue
  fi
  ssize=$(grep -m1 '^| Size ' "$sf" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  case "$ssize" in S|M|L|S/M|M/L) ;; *) report "FAIL $sf: size '$ssize' is not S, M, L or a conditional S/M or M/L" ;; esac
  [ "$size" = "$ssize" ] || report "FAIL $sf: SLICE.md size '$ssize' but ROADMAP says '$size'"
  sstat=$(grep -m1 '^| Status ' "$sf" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
  if [ -n "$sstat" ] && [ "$sstat" != "see ROADMAP.md" ] && [ "$sstat" != "$status" ]; then
    report "FAIL $sf: SLICE.md status '$sstat' but ROADMAP says '$status'"
  fi
done < ROADMAP.md

# ---------------------------------------------------------------- 5
section "5. Change-log slice count equals the tree"
actual=$(find slices -name SLICE.md | wc -l | tr -d ' ')
logged=$(grep -oE 'find slices -name SLICE.md \| wc -l` → \*\*[0-9]+\*\*' ROADMAP.md | grep -oE '[0-9]+\*\*$' | grep -oE '[0-9]+' | tail -1)
if [ -z "$logged" ]; then
  report "FAIL ROADMAP.md: no change-log entry naming 'find slices -name SLICE.md | wc -l'"
elif [ "$logged" != "$actual" ]; then
  report "FAIL ROADMAP.md: change log says $logged slices, tree has $actual"
fi

# ---------------------------------------------------------------- 6
section "6. No reference to a plan path absent from git ls-files"
exists_prefix() { printf '%s\n' "$tracked" | grep -q "^$1"; }
for f in $(git ls-files '*.md'); do
  # doc and slice path references
  grep -oE '(docs/adr/[0-9]{4}|docs/[0-9]{2}|slices/[0-9]{3}|templates/[A-Za-z-]+\.md)[A-Za-z0-9._-]*' "$f" 2>/dev/null | sort -u | while read -r ref; do
    exists_prefix "$ref" || echo "FAIL $f: references '$ref', absent from git ls-files"
  done
  # ADR-NNNN citations
  grep -oE 'ADR-[0-9]{4}' "$f" 2>/dev/null | sort -u | while read -r adr; do
    n=${adr#ADR-}
    exists_prefix "docs/adr/$n" || echo "FAIL $f: cites '$adr', no docs/adr/$n-*.md in git ls-files"
  done
done > /tmp/plan_check_paths.$$ 2>/dev/null
if [ -s /tmp/plan_check_paths.$$ ]; then cat /tmp/plan_check_paths.$$; fail=1; fi
rm -f /tmp/plan_check_paths.$$

section "6b. No slice depends on a slice that does not exist"
for f in $slice_files ROADMAP.md; do
  if [ "$f" = "ROADMAP.md" ]; then
    deps=$(awk -F'|' '/^\| [0-9]{3} \|/{print $2":"$6}' ROADMAP.md)
  else
    deps=$(grep -m1 '^| Depends on ' "$f" | awk -F'|' -v F="$f" '{print F":"$3}')
  fi
  printf '%s\n' "$deps" | while IFS=: read -r who list; do
    [ -z "${list:-}" ] && continue
    for d in $(printf '%s' "$list" | grep -oE '\b[0-9]{3}\b' | sort -u); do
      exists_prefix "slices/$d-" || echo "FAIL $f: '$(echo $who)' depends on slice $d, which has no slices/$d-*/SLICE.md"
    done
  done
done > /tmp/plan_check_deps.$$ 2>/dev/null
if [ -s /tmp/plan_check_deps.$$ ]; then sort -u /tmp/plan_check_deps.$$; fail=1; fi
rm -f /tmp/plan_check_deps.$$

# ---------------------------------------------------------------- 7
section "7. No board identifiers in the tree"
if git grep -nIE '\bSCR-[0-9]+\b' -- '*.md' 'scripts/*' >/dev/null 2>&1; then
  git grep -nIE '\bSCR-[0-9]+\b' -- '*.md' 'scripts/*' | sed 's/^/FAIL /'
  fail=1
fi

section "8. Commit messages: no assistant attribution, every commit signed off"
# Checks the history, not the hook. A bypassed or unconfigured hook still fails here.
for c in $(git log --format=%H); do
  body=$(git log -1 --format=%B "$c")
  bad=$(printf '%s\n' "$body" | grep -nE '^(Co-Authored-By: Claude|Claude-Session:|🤖 Generated with)' || true)
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | while read -r l; do echo "FAIL commit $c: attribution trailer: $l"; done
    fail=1
  fi
  printf '%s\n' "$body" | grep -q '^Signed-off-by: ' \
    || report "FAIL commit $c: no Signed-off-by line ($(git log -1 --format=%s "$c"))"
done

section "10. No reference to the pre-move owner path"
# The repository moved to the ScriptKittyOS organisation. A tracked file still pointing at the
# old owner path sends people, tooling and citations to a repo that is no longer canonical.
# The pattern is COMPOSED, so this file does not contain the literal and needs no exemption.
# Enforcers 2 and 3 each carry a one-entry skip for exactly this reason; here it is avoidable.
stale_owner="$(printf 'Hack%s' 'Tuah')"
if git grep -nI "$stale_owner" -- . >/dev/null 2>&1; then
  git grep -nI "$stale_owner" -- . | sed 's/^/FAIL stale owner path: /'
  fail=1
fi

section "9. Secrets are ignored, as CLAUDE.md claims"
# CLAUDE.md states ".env* is gitignored". A generator run overwrote .gitignore at
# slice 000 and silently removed that rule; nothing caught it. This does.
for f in .env .env.local .env.production; do
  git check-ignore -q "$f" || report "FAIL .gitignore: '$f' is not ignored, but CLAUDE.md says .env* is"
done
grep -q '^!\.env\.example$' .gitignore || true

section "11. Slice lifecycle matches the branch"
# docs/04 defines ready -> in_progress -> done -> approved and nothing checked that a slice ever
# occupies in_progress. Slice 000 ran G1 to G3 reading `ready`, so CLAUDE.md section 0's own
# start-of-session check would have found no live slice. That deviation is recorded in slice
# 000's NOTES.md; this is its enforcer.
#
# Only ROADMAP.md is read: check 4 already asserts SLICE.md agrees with it, so checking both
# would be checking the same fact twice and calling it two.
roadmap_status() {
  awk -F'|' -v I=" $1 " '$2==I{gsub(/^ +| +$/,"",$7); print $7}' ROADMAP.md
}

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$branch" in
  slice/*)
    sid=$(printf '%s' "$branch" | sed -n 's|^slice/\([0-9][0-9][0-9]\)-.*|\1|p')
    if [ -z "$sid" ]; then
      report "FAIL branch '$branch': a slice branch is named slice/NNN-short-name (CLAUDE.md section 4)"
    else
      st=$(roadmap_status "$sid")
      case "$st" in
        in_progress|done) ;;
        "") report "FAIL ROADMAP.md: on branch '$branch' there is no row for slice $sid" ;;
        *) report "FAIL ROADMAP.md: on branch '$branch', slice $sid reads '$st'; work in progress on a slice branch means that slice is in_progress or done" ;;
      esac
    fi
    ;;
  main)
    for row_id in $(awk -F'|' '/^\| [0-9][0-9][0-9] \|/{gsub(/ /,"",$2); print $2}' ROADMAP.md); do
      [ "$(roadmap_status "$row_id")" = "in_progress" ] &&
        report "FAIL ROADMAP.md: slice $row_id reads in_progress on main; a slice is in progress on its own branch"
    done
    ;;
esac

printf '\n'
if [ "$fail" -eq 0 ]; then echo "plan_check: PASS"; else echo "plan_check: FAIL"; fi
exit "$fail"
