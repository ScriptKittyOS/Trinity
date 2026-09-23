#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Is this project's build reproducible? Builds the release twice from a clean tree and compares
# every file in it, byte for byte.
#
# This is not in `mix gate`: it is two full production release builds, which is minutes rather
# than seconds, and the property it checks changes when the toolchain or a dependency changes
# rather than when a line of application code does. It is here so that the claim in
# docs/packaging.md can be re-run by anyone who doubts it, which is the only thing that makes a
# reproducibility claim worth making.
#
# Usage:  ./scripts/check_reproducible.sh [release_name]
# Exit 0 when every file this project produces is identical across the two builds.
set -euo pipefail

RELEASE="${1:-headless}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The Erlang distribution cookie is generated fresh for every release and is a secret. It is
# *supposed* to differ between builds; a fixed one would be a defect, not reproducibility.
EXPECTED_DIFFERENT='releases/COOKIE'

build_and_hash() {
  local out="$1"
  rm -rf _build/prod
  # ERL_AFLAGS is cleared for the same reason mix gate clears it: building deps fetches over TLS,
  # which OTP's ssl cannot do in FIPS mode.
  MIX_ENV=prod ERL_AFLAGS= mix release "$RELEASE" --overwrite >/dev/null
  ( cd "_build/prod/rel/$RELEASE" && find . -type f | sort | xargs sha256sum ) \
    | sed 's|trinity-[0-9][0-9.]*|trinity-VSN|g' > "$out"
}

echo "building $RELEASE (1 of 2)..."
build_and_hash "$WORK/a"
echo "building $RELEASE (2 of 2)..."
build_and_hash "$WORK/b"

total=$(wc -l < "$WORK/a")
diff <(cat "$WORK/a") <(cat "$WORK/b") | grep '^<' | awk '{print $3}' | sed 's|^\./||' > "$WORK/differing" || true
differing=$(wc -l < "$WORK/differing")

echo
echo "files in the release: $total"
echo "files differing:      $differing"

# Split what differs into "this project's own output" and everything else, because they mean
# different things: ours is a defect, a dependency's is upstream's, and the cookie is by design.
ours=$(grep -E '/trinity-VSN/' "$WORK/differing" || true)
cookie=$(grep -Fx "$EXPECTED_DIFFERENT" "$WORK/differing" || true)
theirs=$(grep -vE "/trinity-VSN/|^${EXPECTED_DIFFERENT}\$" "$WORK/differing" || true)

if [ -n "$cookie" ]; then
  echo
  echo "expected, by design:"
  echo "  releases/COOKIE  (a per-release secret; a fixed one would be the defect)"
fi

if [ -n "$theirs" ]; then
  echo
  echo "non-deterministic dependencies (upstream's, not this project's):"
  echo "$theirs" | sed 's/^/  /'
fi

if [ -n "$ours" ]; then
  echo
  echo "THIS PROJECT'S OWN OUTPUT IS NOT REPRODUCIBLE:"
  echo "$ours" | sed 's/^/  /'
  echo
  echo "check_reproducible: FAIL"
  exit 1
fi

echo
echo "check_reproducible: PASS - every module this project compiles is bit-for-bit identical"
echo "across two independent builds from a clean tree."
