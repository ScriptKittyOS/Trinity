#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The Tier 3 gates' container steps (slice 134), one subcommand at a time, so the same commands
# rerun on another image (a hardened build of the same version: TIER3_IMAGE=<registry>/<path>:0.40.0).
#
#   scripts/tier3/gates.sh package <gguf> <name>   sign a GGUF as a producer would (OMS, then an ORAS
#                                                  artifact cosign-signed in a loopback registry) and
#                                                  save it as an OCI layout: the delivery to import
#   scripts/tier3/gates.sh serve                   start the service (CPU, --memory=16g, loopback port)
#   scripts/tier3/gates.sh import <name> <model>   run mix trinity.tier3.import on a delivery
#   scripts/tier3/gates.sh offline <name>          Gate 4: a second container with --network none over
#                                                  a copy of the verified models directory
#   scripts/tier3/gates.sh down                    remove the containers
#
# Gates 1, 2, 3 and 5 are mix scripts in this directory (parity.exs, truncation.exs,
# digest_pin.exs, bench.exs), run against the served model with the import's record.
#
# Environment: TIER3_IMAGE (ollama/ollama:0.40.0), TIER3_WORK (where keys, deliveries, records and
# the models directory go; outside the tree), TIER3_PORT (11534), COSIGN, ORAS, MODEL_SIGNING
# (the programs). Private keys are made here, in TIER3_WORK/keys, and never leave it.
set -euo pipefail

image="${TIER3_IMAGE:-ollama/ollama:0.40.0}"
work="${TIER3_WORK:?set TIER3_WORK to a directory outside the tree}"
port="${TIER3_PORT:-11534}"
cosign="${COSIGN:?set COSIGN to the cosign program}"
oras="${ORAS:?set ORAS to the oras program}"
model_signing="${MODEL_SIGNING:?set MODEL_SIGNING to the model_signing program}"
serve_name=tier3-ollama
offline_name=tier3-offline
here="$(cd "$(dirname "$0")" && pwd)"
tree="$(cd "$here/../.." && pwd)"
mkdir -p "$work"

keys() {
  mkdir -p "$work/keys"
  if [ ! -f "$work/keys/cosign.pub" ]; then
    (cd "$work/keys" && COSIGN_PASSWORD= "$cosign" generate-key-pair >/dev/null)
  fi
  if [ ! -f "$work/keys/oms.pub" ]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/keys/oms.key"
    openssl ec -in "$work/keys/oms.key" -pubout -out "$work/keys/oms.pub" 2>/dev/null
  fi
  chmod 600 "$work/keys/"*.key
}

package() {
  local gguf="$1" name="$2" d="$work/delivery/$2"
  keys
  rm -rf "$d"; mkdir -p "$d/model"
  cp "$gguf" "$d/model/"
  echo "== OMS: model_signing sign key over $d/model"
  "$model_signing" sign key --private_key "$work/keys/oms.key" --signature "$d/model.sig" "$d/model"
  echo "== a loopback registry, oras push, cosign sign (no transparency log), cosign save"
  docker run -d --rm --name tier3-registry -p 127.0.0.1:5134:5000 registry:2 >/dev/null
  trap 'docker stop tier3-registry >/dev/null 2>&1 || true' RETURN
  sleep 2
  local ref="127.0.0.1:5134/tier3/$name:v1"
  # The layers' titles are the files' base names: push from a directory holding both.
  mkdir -p "$d/push"; ln "$d/model/$(basename "$gguf")" "$d/model.sig" "$d/push/"
  (cd "$d/push" && "$oras" push --plain-http "$ref" --artifact-type application/vnd.trinity.tier3.model.v1 \
     "$(basename "$gguf"):application/octet-stream" "model.sig:application/vnd.dev.sigstore.bundle.v0.3+json" >/dev/null)
  rm -rf "$d/push"
  local digest; digest="$("$oras" resolve --plain-http "$ref")"
  echo "artifact $ref@$digest"
  COSIGN_PASSWORD= "$cosign" sign --key "$work/keys/cosign.key" --use-signing-config=false --tlog-upload=false -y \
    "127.0.0.1:5134/tier3/$name@$digest" 2>&1 | grep -v -i deprecated
  "$cosign" save --dir "$d/layout" "127.0.0.1:5134/tier3/$name@$digest"
  echo "delivery $d/layout ($(du -sh "$d/layout" | cut -f1))"
}

serve() {
  mkdir -p "$work/ollama-models"
  docker rm -f "$serve_name" >/dev/null 2>&1 || true
  docker run -d --name "$serve_name" --memory=16g --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e OLLAMA_MODELS=/models -v "$work/ollama-models:/models" -p "127.0.0.1:$port:11434" "$image" >/dev/null
  for _ in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:$port/api/version" 2>/dev/null && echo && break
    sleep 1
  done
  docker image inspect "$image" --format 'image {{.Id}} {{json .RepoDigests}}'
}

import_() {
  local name="$1" model="$2" d="$work/delivery/$1"
  mkdir -p "$work/records"
  (cd "$tree" && mix trinity.tier3.import --layout "$d/layout" --cosign-key "$work/keys/cosign.pub" \
     --oms-key "$work/keys/oms.pub" --base-url "http://127.0.0.1:$port" --model "$model" \
     --cosign "$cosign" --model-signing "$model_signing" --out "$work/records")
}

offline() {
  local name="$1"
  rm -rf "$work/offline-models"; cp -a "$work/ollama-models" "$work/offline-models"
  echo "== the directory, verified before the start: every blob's SHA-256 is its name"
  local bad=0
  for b in "$work/offline-models/blobs/"sha256-*; do
    [ "sha256-$(sha256sum "$b" | cut -c1-64)" = "$(basename "$b")" ] || { echo "MISMATCH $b"; bad=1; }
  done
  echo "blobs $(ls "$work/offline-models/blobs" | wc -l), mismatches $bad"
  local m="$work/offline-models/manifests-v2/ollama.com/library/$name/latest"
  echo "manifest $(sha256sum "$m" | cut -c1-64) (the /api/tags digest), layers: $(python3 -c 'import json,sys; print([l["digest"] for l in json.load(open(sys.argv[1]))["layers"]])' "$m")"
  [ "$bad" = 0 ] || return 1
  docker rm -f "$offline_name" >/dev/null 2>&1 || true
  # Read-write: Ollama 0.40.0 removes the legacy manifests/ directory at start (a read-only mount
  # stops it with "remove /models/manifests: read-only file system"). The copy is disposable.
  docker run -d --name "$offline_name" --network none --memory=16g --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e OLLAMA_MODELS=/models -v "$work/offline-models:/models" "$image" >/dev/null
  sleep 3
  echo "== the container's network: mode $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$offline_name"); interfaces:"
  docker run --rm --network "container:$offline_name" alpine:3.19 sh -c 'ls /sys/class/net; ip route 2>/dev/null || true'
  local probe=(docker run --rm --network "container:$offline_name" alpine:3.19)
  echo "== /api/version and /api/tags, from inside its network namespace"
  "${probe[@]}" wget -qO- http://127.0.0.1:11434/api/version; echo
  "${probe[@]}" wget -qO- http://127.0.0.1:11434/api/tags; echo
  echo "== /api/embed, truncate:false"
  "${probe[@]}" wget -qO- --header 'Content-Type: application/json' \
    --post-data "{\"model\":\"$name\",\"input\":[\"The person's dog is called Rex.\"],\"truncate\":false,\"options\":{\"num_ctx\":2048}}" \
    http://127.0.0.1:11434/api/embed | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d["embeddings"][0]; print("embeddings", len(d["embeddings"]), "dim", len(v), "norm2 %.6f" % sum(x*x for x in v), "prompt_eval_count", d["prompt_eval_count"])'
  echo "== a pull, which needs the network"
  docker exec "$offline_name" ollama pull all-minilm 2>&1 | tail -1 || true
  echo "== the server's log"
  docker logs "$offline_name" 2>&1 | grep -v GIN | tail -5
}

down() {
  docker rm -f "$serve_name" "$offline_name" tier3-registry >/dev/null 2>&1 || true
}

case "${1:-}" in
  package) package "$2" "$3" ;;
  serve) serve ;;
  import) import_ "$2" "$3" ;;
  offline) offline "$2" ;;
  down) down ;;
  *) sed -n 5,22p "$0"; exit 2 ;;
esac
