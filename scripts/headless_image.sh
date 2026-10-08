#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Builds the hardened headless image (slice 130) the way Iron Bank's pipeline would, so the image
# this project publishes and the one it would submit come from the same Dockerfile and the same
# inputs (docs/regulated/headless-image.md).
#
#   scripts/headless_image.sh stage DIR          assemble a build context in DIR
#   scripts/headless_image.sh build TAG [DIR]    stage into DIR (default: a temporary directory),
#                                                then build TAG with ci/headless/bases.env
#
# `stage` does what Iron Bank's prebuild does: for each resource in
# ci/ironbank/hardening_manifest.yaml it downloads the URL, checks the digest, and places the file
# in the context under its filename. A download is cached (TRINITY_RESOURCE_CACHE, default
# ~/.cache/trinity/ironbank-resources) and re-checked on every use, so a corrupted cache fails
# rather than building. The two held resources (ci/headless/submission_holds.yaml) are produced
# from this checkout: its tracked files, and its prod Hex tree.
#
# This script reaches the network on purpose; it is the pipeline's part, not the build's. The
# Dockerfile and the submission's own scripts never do, and `mix trinity.ironbank.lint` holds
# that.
set -euo pipefail
cd "$(dirname "$0")/.."

cache="${TRINITY_RESOURCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/trinity/ironbank-resources}"

die() {
  echo "headless_image: $*" >&2
  exit 1
}

# One line per manifest resource: filename, url, digest type, digest value, tab separated.
resources() {
  python3 -c '
import sys, yaml
manifest = yaml.safe_load(open("ci/ironbank/hardening_manifest.yaml"))
for r in manifest.get("resources", []):
    v = r.get("validation") or {}
    print("\t".join([r["filename"], r["url"], v.get("type", ""), v.get("value", "")]))
'
}

verify() { # file type value
  local file=$1 type=$2 value=$3 actual
  case "$type" in
    sha256) actual=$(sha256sum "$file" | cut -d' ' -f1) ;;
    sha512) actual=$(sha512sum "$file" | cut -d' ' -f1) ;;
    *) die "$file: the manifest gives no sha256 or sha512 digest" ;;
  esac
  [ "$actual" = "$value" ]
}

fetch() { # filename url type value
  local filename=$1 url=$2 type=$3 value=$4
  if [ -f "$cache/$filename" ] && verify "$cache/$filename" "$type" "$value"; then
    return 0
  fi
  echo "headless_image: fetching $filename" >&2
  curl -fsSL --retry 3 -o "$cache/$filename.part" "$url"
  verify "$cache/$filename.part" "$type" "$value" ||
    die "$filename from $url does not match its $type digest in the manifest"
  mv "$cache/$filename.part" "$cache/$filename"
}

# A tar.gz that depends only on its contents: names sorted, owners and times fixed, gzip without
# a timestamp. Two stages of the same tree give the same bytes. The fixed time is 2000-01-01, not
# the epoch: Mix decides what to compile by comparing a source's mtime with its target's, and
# reads a missing target as mtime 0, so sources stamped 0 look up to date and are never compiled
# (measured: `expo`'s parser was skipped and its compile failed).
deterministic_tgz() { # out dir paths-from-stdin (NUL separated)
  local out=$1 dir=$2
  tar -C "$dir" --null --no-recursion -T - --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='@946684800' --mode='go-w' -cf - | gzip -n >"$out"
}

stage() {
  local dir=$1
  [ -n "$dir" ] || die "stage needs a directory"
  rm -rf "$dir"
  mkdir -p "$dir" "$cache"

  cp ci/ironbank/Dockerfile "$dir/"
  if [ -d ci/ironbank/scripts ]; then cp -R ci/ironbank/scripts "$dir/"; fi

  while IFS=$'\t' read -r filename url type value; do
    fetch "$filename" "$url" "$type" "$value"
    cp "$cache/$filename" "$dir/$filename"
  done < <(resources)

  # Held resource 1: the tracked files of this checkout, as they are on disk.
  git ls-files -z | deterministic_tgz "$dir/trinity-src.tar.gz" .

  # Held resource 2: the prod Hex tree, fetched into a scratch project with this checkout's mix
  # files, so nothing in the working tree's own deps/ leaks in.
  local hex
  hex=$(mktemp -d)
  cp mix.exs mix.lock "$hex/"
  cp -R config "$hex/"
  (cd "$hex" && MIX_ENV=prod mix deps.get --only prod >&2)
  (cd "$hex" && find deps -print0 | sort -z) | deterministic_tgz "$dir/trinity-hex-deps.tar.gz" "$hex"
  rm -rf "$hex"

  echo "headless_image: staged $(find "$dir" -maxdepth 1 -type f | wc -l) files in $dir" >&2
}

build() {
  local tag=$1 dir=${2:-}
  [ -n "$tag" ] || die "build needs an image tag"
  if [ -z "$dir" ]; then
    dir=$(mktemp -d)
    # Expanded now, not at exit: `dir` is local to this function and is gone by the time the
    # EXIT trap runs, so a trap that read it then failed under `set -u` ("dir: unbound
    # variable"), exited 1 after a successful build and left the context behind (slice 131
    # NOTES, F-131-2).
    # shellcheck disable=SC2064
    trap "rm -rf '$dir'" EXIT
  fi
  stage "$dir"

  local args=()
  while IFS= read -r line; do
    case "$line" in '' | \#*) continue ;; esac
    args+=(--build-arg "$line")
  done <ci/headless/bases.env

  docker build "${args[@]}" -t "$tag" -f "$dir/Dockerfile" "$dir"
}

case "${1:-}" in
  stage) stage "${2:-}" ;;
  build) build "${2:-}" "${3:-}" ;;
  *) die "usage: $0 stage DIR | build TAG [DIR]" ;;
esac
