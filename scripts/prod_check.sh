#!/usr/bin/env sh
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The release half of the gate. Added after slice 062, for a defect the gate could not see:
# `Plug.Builder` calls a plug's `init/1` at COMPILE TIME when MIX_ENV=prod and escapes what it
# returns into the endpoint, so an anonymous function there breaks the release build and nothing
# else. `mix gate` runs in MIX_ENV=test, where `init/1` is called per request, so every gate was
# green over a tree whose release could not compile; the three-OS `package` workflow found it at
# the tag, which is after approval (slice 062 NOTES, F5).
#
# Three commands, each for a class the one before it cannot see:
#
#   1. the tree compiles in prod            — compile-time differences (the defect above)
#   2. the release assembles                — the release's application list and boot scripts
#   3. the release evaluates its config     — config/runtime.exs's `config_env() == :prod`
#                                             branch, 116 lines that nothing else in the gate
#                                             or in CI ever executes
#
# What it does NOT prove, said plainly: nothing here builds a Burrito binary, loads a NIF under
# musl (slice 013's mdex finding), builds the Tauri shell, or runs on macOS or Windows. That is
# the `package` workflow's job and it stays the `package` workflow's job.
#
# POSIX sh, and so not run on a Windows developer's machine; CI covers it there.
# The gate invokes it as `cmd env ERL_AFLAGS= ./scripts/prod_check.sh`: on the FIPS leg it runs
# outside FIPS mode, because compiling prod builds the dependencies and `tokenizers` fetches a
# precompiled NIF over TLS, which OTP's ssl cannot do in the mode. Compiling for release is not
# a FIPS property; the FIPS properties are `mix test --trace test/fips`, which stays in the mode.
set -eu
cd "$(dirname "$0")/.."

build_root="${MIX_BUILD_ROOT:-_build}"
rel="$build_root/prod/rel/headless/bin/headless"

echo "== 1. the tree compiles in prod =="
MIX_ENV=prod mix compile --warnings-as-errors

echo "== 2. the headless release assembles =="
# Assets are not deployed here: this step is about the release's own assembly, and
# `mix assets.deploy` is the packaging workflow's concern.
MIX_ENV=prod mix release headless --overwrite --quiet

echo "== 3. the release evaluates its runtime configuration =="
# `eval` runs the release's config providers, so config/runtime.exs's prod branch is executed
# with no environment prepared for it, which is how a packaged binary is first started.
"$rel" eval 'IO.puts("prod boot config ok")'

echo "prod_check: PASS"
