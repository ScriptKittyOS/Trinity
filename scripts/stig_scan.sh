#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Evaluates a built headless image against the DISA STIG profile for RHEL 9, the way Iron Bank's
# pipeline does for a UBI9 image (slice 130, AC5): OpenSCAP, profile
# xccdf_org.ssgproject.content_profile_stig, datastream ssg-rhel9-ds.xml from the SCAP Security
# Guide release pinned below. The results feed `mix trinity.image.stig`, which turns them into
# the image's STIG applicability statement.
#
#   scripts/stig_scan.sh IMAGE OUTDIR    writes OUTDIR/stig-results.xml and OUTDIR/stig-report.html
#
# The image is exported and unpacked as root inside the scanner container, so ownership and modes
# are the image's own, and OpenSCAP reads it through OSCAP_PROBE_ROOT. The scanner is UBI's own
# openscap-scanner package, installed into the builder base ci/headless/bases.env pins. The export
# includes the container marker /.dockerenv, so rules whose platform is a machine evaluate as not
# applicable, as they do under Iron Bank's oscap-podman.
#
# This script reaches the network (the guide's release, UBI's repositories); it is a CI and
# developer tool, never part of an image build.
set -euo pipefail
cd "$(dirname "$0")/.."

image=${1:?usage: $0 IMAGE OUTDIR}
out=${2:?usage: $0 IMAGE OUTDIR}

ssg_version=0.1.82
ssg_sha512=1caea418f0a5aaef7025e1655ca45a80942ea87ee832b943644ba6f9991b14a6ac5b35dddcd04b754e1fc8fbdee7b7f394507d24b123e821cca0354dc4e03cfd
cache="${TRINITY_RESOURCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/trinity/ironbank-resources}"
zip="$cache/scap-security-guide-$ssg_version.zip"

mkdir -p "$cache" "$out"
out=$(cd "$out" && pwd)

if [ ! -f "$zip" ] || [ "$(sha512sum "$zip" | cut -d' ' -f1)" != "$ssg_sha512" ]; then
  curl -fsSL --retry 3 -o "$zip.part" \
    "https://github.com/ComplianceAsCode/content/releases/download/v$ssg_version/scap-security-guide-$ssg_version.zip"
  [ "$(sha512sum "$zip.part" | cut -d' ' -f1)" = "$ssg_sha512" ] ||
    { echo "stig_scan: the guide does not match its pinned SHA-512" >&2; exit 1; }
  mv "$zip.part" "$zip"
fi

ssg=$(mktemp -d)
cid=""
trap 'rm -rf "$ssg"; if [ -n "$cid" ]; then docker rm "$cid" >/dev/null; fi' EXIT
unzip -q -j "$zip" "scap-security-guide-$ssg_version/ssg-rhel9-ds.xml" -d "$ssg"

builder=$(awk -F= '$1 == "BASE_REGISTRY" { r = $2 } $1 == "BUILDER_IMAGE" { i = $2 } $1 == "BUILDER_TAG" { t = $2 }
  END { print r "/" i ":" t }' ci/headless/bases.env)

cid=$(docker create "$image")
docker export "$cid" |
  docker run --rm -i \
    -v "$ssg:/ssg:ro" -v "$out:/out" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$builder" bash -c '
      set -euo pipefail
      dnf -q -y install --setopt=install_weak_deps=False openscap-scanner >/dev/null
      oscap --version | head -1 >&2
      mkdir /rootfs
      tar -x -C /rootfs
      set +e
      OSCAP_PROBE_ROOT=/rootfs oscap xccdf eval \
        --profile xccdf_org.ssgproject.content_profile_stig \
        --results /out/stig-results.xml --report /out/stig-report.html \
        /ssg/ssg-rhel9-ds.xml >/out/stig-oscap.log 2>&1
      status=$?
      set -e
      chown "$HOST_UID:$HOST_GID" /out/stig-results.xml /out/stig-report.html /out/stig-oscap.log
      # 0: every rule passed; 2: at least one did not. Anything else is an evaluation error.
      if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
        echo "stig_scan: oscap exited $status" >&2
        tail -20 /out/stig-oscap.log >&2
        exit "$status"
      fi
    '
echo "stig_scan: wrote $out/stig-results.xml" >&2
