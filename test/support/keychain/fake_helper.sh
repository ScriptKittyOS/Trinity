#!/bin/sh
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 100. A stand-in for the Tauri shell's keychain mode (`trinity --keychain <op> <account>`)
# with the same protocol: the value travels as hex, on stdin for `set` and on stdout for `get`,
# never on argv. Exit 0 done, 3 no such entry, 4 the keychain cannot be reached, 2 usage.
#
# A test copies this file into its own directory. The "keychain" is `store/` beside the copy,
# every argv is appended to `argv.log` beside it (so a test can assert the value never rode on
# the command line), and a file named `broken` beside it makes every operation exit 4.
here=$(cd "$(dirname "$0")" && pwd)
store="$here/store"
mkdir -p "$store"
printf '%s\n' "$*" >> "$here/argv.log"
[ -e "$here/broken" ] && { echo "keychain unreachable" >&2; exit 4; }
[ "$1" = "--keychain" ] || exit 2
case "$2" in
  probe) exit 0 ;;
  set) IFS= read -r line || exit 2; printf '%s' "$line" > "$store/$3"; exit 0 ;;
  get) [ -f "$store/$3" ] || exit 3; cat "$store/$3"; echo; exit 0 ;;
  delete) [ -f "$store/$3" ] || exit 3; rm -f "$store/$3"; exit 0 ;;
  *) exit 2 ;;
esac
