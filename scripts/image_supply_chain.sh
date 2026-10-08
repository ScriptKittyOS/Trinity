#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Signs a published headless image and attaches its evidence (slice 131), so a consumer holding
# only the image and the project's public key can check all of it (docs/regulated/image-verify.md).
#
#   scripts/image_supply_chain.sh attach REGISTRY/REPO@sha256:DIGEST --key KEYREF \
#     --provenance provenance.json --sbom sbom.cdx.json --aibom ai-bom.cdx.json
#
# Four statements, each signed by the held key and stored in the registry beside the image as an
# OCI referrer of its digest:
#
#   the signature        cosign sign                        https://sigstore.dev/cosign/sign/v1
#   build provenance     cosign attest --type slsaprovenance1   https://slsa.dev/provenance/v1
#   the SBOM             cosign attest --type cyclonedx         https://cyclonedx.org/bom
#   the AI-BOM           cosign attest --type <AIBOM_TYPE below>
#
# The key is a held key, never a transparency log (slice 131 NOTES, D-131-1): KEYREF is anything
# cosign takes for --key (a file, env://VAR, a KMS URI, pkcs11:), and its password, if any, comes
# from COSIGN_PASSWORD. Nothing is uploaded to a public log, so a consumer with no network verifies
# exactly what a connected one does.
#
# The bills are inputs, generated first and checked by their own tasks: `mix trinity.image.provenance`,
# `mix trinity.sbom`, `mix trinity.image.aibom`. The reference must carry a digest, because a tag can
# move between the push and the signature.
#
# COSIGN names the cosign program (default `cosign`). IMAGE_REGISTRY_INSECURE=1 lets cosign talk
# plain HTTP to a registry on the loopback, which is what the tests use; never set it for a real one.
set -euo pipefail

AIBOM_TYPE="https://github.com/ScriptKittyOS/Trinity/blob/main/docs/regulated/image-verify.md#ai-bom"
cosign_bin="${COSIGN:-cosign}"

die() {
  echo "image_supply_chain: $*" >&2
  exit 1
}

attach() {
  local ref="${1:-}" key="" provenance="" sbom="" aibom=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --key) key=$2 ;;
      --provenance) provenance=$2 ;;
      --sbom) sbom=$2 ;;
      --aibom) aibom=$2 ;;
      *) die "unknown argument $1" ;;
    esac
    shift 2
  done

  case "$ref" in
    *@sha256:*) ;;
    *) die "$ref is not pinned by digest (REGISTRY/REPO@sha256:HEX)" ;;
  esac
  [ -n "$key" ] || die "--key is required"
  for f in "$provenance" "$sbom" "$aibom"; do
    [ -n "$f" ] && [ -f "$f" ] || die "--provenance, --sbom and --aibom must each name a file"
  done
  command -v "$cosign_bin" >/dev/null || die "cosign not found: $cosign_bin"

  # A held key and no log: the signing config would otherwise name Sigstore's public services.
  local common=(--yes --key "$key" --use-signing-config=false --tlog-upload=false)
  if [ "${IMAGE_REGISTRY_INSECURE:-}" = "1" ]; then
    common+=(--allow-insecure-registry --allow-http-registry)
  fi

  "$cosign_bin" sign "${common[@]}" "$ref"
  "$cosign_bin" attest "${common[@]}" --type slsaprovenance1 --predicate "$provenance" "$ref"
  "$cosign_bin" attest "${common[@]}" --type cyclonedx --predicate "$sbom" "$ref"
  "$cosign_bin" attest "${common[@]}" --type "$AIBOM_TYPE" --predicate "$aibom" "$ref"
  echo "image_supply_chain: signed $ref and attached provenance, SBOM and AI-BOM" >&2
}

case "${1:-}" in
  attach)
    shift
    attach "$@"
    ;;
  aibom-type) echo "$AIBOM_TYPE" ;;
  *) die "usage: $0 attach REGISTRY/REPO@sha256:DIGEST --key KEYREF --provenance F --sbom F --aibom F" ;;
esac
