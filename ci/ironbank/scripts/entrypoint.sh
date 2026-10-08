#!/bin/sh
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The headless image's entrypoint (slice 130). The release's start script reads an Erlang
# distribution cookie and stops without one. A cookie baked into a published image is a credential
# everyone who pulls the image holds, so the image carries none, and this script gives each
# container its own random one unless RELEASE_COOKIE is already set. The image runs with
# distribution off (RELEASE_DISTRIBUTION=none), so the cookie only satisfies the script; if an
# operator turns distribution on, it is at least not a value anyone else knows.
set -eu

if [ -z "${RELEASE_COOKIE:-}" ]; then
  RELEASE_COOKIE=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  export RELEASE_COOKIE
fi

exec "$@"
