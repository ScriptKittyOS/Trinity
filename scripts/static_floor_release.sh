#!/usr/bin/env sh
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 133, AC8: a release assembled WITHOUT the neural group (nx, exla, xla, axon, bumblebee,
# tokenizers) boots, embeds and recalls through the static space, as a spawned process.
#
#   TRINITY_STATIC_MODEL_DIR=<dir holding the artifact> ./scripts/static_floor_release.sh
#
# Four steps, each printing what it found:
#   1. compile the tree for prod with TRINITY_WITHOUT_ML=1, in a build root of its own
#      (FLOOR_BUILD_ROOT, default ../_build_floor), warnings as errors
#   2. assemble the headless release from that build
#   3. list the release's lib/ and refuse it if any of the group is there
#   4. boot it (`bin/headless eval`, its own XDG_DATA_HOME), write two memories, recall one,
#      and print the markers the caller asserts on
#
# The weights are not in the tree (slice 133 NOTES, D7): the release reads them from
# TRINITY_STATIC_MODEL_DIR, as an operator-installed artifact would be read from the data dir.
set -eu
cd "$(dirname "$0")/.."

: "${TRINITY_STATIC_MODEL_DIR:?set it to the directory holding static-retrieval-mrl-en-v1-256-int8.tsw}"
build_root="${FLOOR_BUILD_ROOT:-../_build_floor}"
work="$(mktemp -d "${TMPDIR:-/tmp}/static-floor.XXXXXX")"
rel="$work/rel"
trap 'rm -rf "$work"' EXIT

echo "== 1. compile without the neural group =="
TRINITY_WITHOUT_ML=1 MIX_ENV=prod MIX_BUILD_ROOT="$build_root" mix compile --force --warnings-as-errors

echo "== 2. assemble the headless release =="
TRINITY_WITHOUT_ML=1 MIX_ENV=prod MIX_BUILD_ROOT="$build_root" \
  mix release headless --path "$rel" --overwrite --quiet

echo "== 3. the release's applications =="
ls "$rel/lib" | sed 's/-[0-9][0-9.]*$//' | sort | tr '\n' ' '
echo
if ls "$rel/lib" | grep -E '^(nx|exla|xla|axon|bumblebee|tokenizers)-'; then
  echo "FLOOR_GROUP_PRESENT"
  exit 2
fi
echo "FLOOR_GROUP_ABSENT"

echo "== 4. boot, embed, recall =="
# The desktop sidecar's heartbeat listens on a Unix socket under TMPDIR, and a socket path has
# a length limit (108 bytes on Linux): a long TMPDIR makes the listener fail with :einval and the
# boot with it. The node gets a short one.
XDG_DATA_HOME="$work/data" TRINITY_STATIC_MODEL_DIR="$TRINITY_STATIC_MODEL_DIR" \
  TMPDIR="${FLOOR_NODE_TMPDIR:-/tmp}" \
  "$rel/bin/headless" eval '
    {:ok, _} = Application.ensure_all_started(:trinity)
    alias Trinity.Memory.{AlwaysOn, Retriever, Semantic, Spaces}
    IO.puts("FLOOR_EMBEDDER " <> inspect(Trinity.Memory.Embedder.impl()))
    IO.puts("FLOOR_NX_LOADABLE " <> inspect(Code.ensure_loaded?(Nx)))
    IO.puts("FLOOR_STATUS " <> inspect(Semantic.status()))
    {:ok, persona} = Trinity.Personas.create(%{name: "floor"})
    scope = AlwaysOn.persona_scope(persona.id)
    for {k, body} <- [{"rex", "The person'"'"'s dog is called Rex."}, {"lisbon", "The person moved to Lisbon last spring."}] do
      {:ok, _} = Semantic.add(%{persona_id: persona.id, scope: scope, key: k, body: body}, by: "floor")
    end
    hits = Retriever.relevant(persona.id, nil, "what is my dog named?", touch: false)
    IO.puts("FLOOR_SPACE " <> Spaces.active().id <> " " <> Spaces.active().quantization)
    IO.puts("FLOOR_RECALL " <> inspect(Enum.map(hits, &{&1.kind, &1.found_by, &1.text})))
    System.halt(0)
  '
