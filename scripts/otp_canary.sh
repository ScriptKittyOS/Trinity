#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The OTP canary (owner decision D2, ADR-0014). The container images run the OTP that
# ci/container.tool-versions names; the desktop runs the one .tool-versions names, which can only
# be a version whose ERTS Burrito can download for every desktop target. This asks whether that
# is true yet of the container's OTP, and when it is, moves the desktop pin to it.
#
#   scripts/otp_canary.sh probe   one line per target URL, then `result=agree|missing|ready` and
#                                 `version=...`, in the key=value form $GITHUB_OUTPUT takes
#   scripts/otp_canary.sh flip    writes the container's OTP into .tool-versions and the
#                                 Erlang/OTP row of lib/trinity/versions.ex (then run
#                                 `mix versions.gen`)
#
# The URL templates are Burrito 1.6.0's (deps/burrito/lib/util/erts_universal_machine_fetcher.ex);
# test/otp_canary_test.exs fails if they drift from that file. The targets are mix.exs's three:
# linux_x86_64 and macos_aarch64 from Burrito's CDN (macOS takes the universal build), and
# windows_x86_64 from the OTP release page.
#
# `probe` reaches the network; `flip` does not. TRINITY_REPO names another checkout to act on.
set -euo pipefail
cd "${TRINITY_REPO:-$(dirname "$0")/..}"

linux_url='https://beam-machine-universal.b-cdn.net/OTP-{OTP_VERSION}/linux/{ARCH}/any/otp_{OTP_VERSION}_linux_any_{ARCH}.tar.gz'
mac_url='https://beam-machine-universal.b-cdn.net/OTP-{OTP_VERSION}/macos/universal/otp_{OTP_VERSION}_macos_universal.tar.gz'
windows_url='https://github.com/erlang/otp/releases/download/OTP-{OTP_VERSION}/otp_win64_{OTP_VERSION}.exe'

erlang_pin() { awk '$1 == "erlang" { print $2 }' "$1"; }

container=$(erlang_pin ci/container.tool-versions)
desktop=$(erlang_pin .tool-versions)
[ -n "$container" ] && [ -n "$desktop" ] || {
  echo "otp_canary: ci/container.tool-versions and .tool-versions must each pin erlang" >&2
  exit 2
}

url() { # template arch
  local u=${1//\{OTP_VERSION\}/$container}
  printf '%s\n' "${u//\{ARCH\}/$2}"
}

probe() {
  if [ "$container" = "$desktop" ]; then
    echo "result=agree"
    echo "version=$container"
    return 0
  fi
  local missing=0 status u
  for u in "$(url "$linux_url" x86_64)" "$(url "$mac_url" -)" "$(url "$windows_url" -)"; do
    status=$(curl -s -o /dev/null -I -L --retry 2 --max-time 30 -w '%{http_code}' "$u" || true)
    echo "probe $status $u" >&2
    [ "$status" = 200 ] || missing=1
  done
  if [ "$missing" = 0 ]; then echo "result=ready"; else echo "result=missing"; fi
  echo "version=$container"
}

# Exact replacements, each refused unless its old text occurs exactly once, and all checked
# before any file is written, so a tree that has drifted from what this script expects fails
# here rather than being half-edited. Arguments: file old new, repeated.
replace_all_once() {
  python3 -I - "$@" <<'EOF'
import sys
args = sys.argv[1:]
edits = [args[i:i + 3] for i in range(0, len(args), 3)]
texts = {}
for path, old, new in edits:
    text = texts.setdefault(path, open(path, encoding="utf-8").read())
    count = text.count(old)
    if count != 1:
        sys.exit(f"otp_canary: {path}: expected {old!r} once, found it {count} times; nothing written")
    texts[path] = text.replace(old, new)
for path, text in texts.items():
    open(path, "w", encoding="utf-8").write(text)
EOF
}

flip() {
  if [ "$container" = "$desktop" ]; then
    echo "otp_canary: the pins already agree at $container; nothing to flip" >&2
    exit 0
  fi
  replace_all_once \
    .tool-versions "erlang $desktop" "erlang $container" \
    lib/trinity/versions.ex "pin: \"**$desktop**\"" "pin: \"**$container**\"" \
    lib/trinity/versions.ex "{:file, \".tool-versions\", \"erlang $desktop\"}" \
    "{:file, \".tool-versions\", \"erlang $container\"}"
  echo "otp_canary: desktop pin $desktop -> $container"
}

case "${1:-}" in
  probe) probe ;;
  flip) flip ;;
  *) echo "usage: $0 probe|flip" >&2; exit 2 ;;
esac
