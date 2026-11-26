#!/usr/bin/env bash
# Which images the monitor must NOT publish by itself right now. Used by
# upstream-check.yml; the file it reads is the switch a maintainer flips
# while a bad release is being investigated or rolled back
# (docs/operations.md, "Rolling back a release").
#
# Usage:  hold.sh [<file>]     default .github/monitor-hold
# The file: one image per line, `resolver` or `sidecar`; blank lines and
# everything after a `#` are ignored. A missing or comment-only file holds
# nothing.
# Output (stdout): hold=none|resolver|sidecar|both
# Exit status: 1 on any other word — a typo must stop the run where it is
# seen, not silently hold nothing (or everything).
set -euo pipefail

FILE=${1:-.github/monitor-hold}
resolver=0; sidecar=0
if [ -e "$FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    read -r word rest <<<"$line" || true
    [ -n "${word:-}" ] || continue
    [ -z "${rest:-}" ] || { echo "::error::$FILE: one image per line, got '$line'" >&2; exit 1; }
    case "$word" in
      resolver) resolver=1 ;;
      sidecar)  sidecar=1 ;;
      *) echo "::error::$FILE: unknown image '$word' (resolver or sidecar)" >&2; exit 1 ;;
    esac
  done < "$FILE"
fi
case "$resolver$sidecar" in
  00) echo hold=none ;;
  10) echo hold=resolver ;;
  01) echo hold=sidecar ;;
  11) echo hold=both ;;
esac
