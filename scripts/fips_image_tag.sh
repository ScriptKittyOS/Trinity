#!/usr/bin/env sh
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The FIPS leg image's tag: the first sixteen hex digits of the SHA-256 over the two files
# that define the image (slice 003, docs/fips-leg.md). The image workflow pushes under it and
# the gate leg pulls by it, so the two can never disagree about which image a tree wants, and
# a change to either file is a new tag, never a rebuild under an old one.
#
#   scripts/fips_image_tag.sh          prints the tag
#   scripts/fips_image_tag.sh --ref    prints the full image reference
set -eu
cd "$(dirname "$0")/.."
tag=$(cat .tool-versions ci/fips/Containerfile | sha256sum | cut -c1-16)
case "${1:-}" in
  --ref) printf 'ghcr.io/scriptkittyos/trinity-fips:%s\n' "$tag" ;;
  "") printf '%s\n' "$tag" ;;
  *) echo "usage: $0 [--ref]" >&2; exit 2 ;;
esac
