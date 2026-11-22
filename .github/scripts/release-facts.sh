#!/usr/bin/env bash
# Registry facts about one release, for release-mode.sh (release.yml,
# updater.yml) and release-health.sh (upstream-check.yml).
#
# Usage: release-facts.sh <immutable-tag> <hub-image> <ghcr-image> <mutable-tag>...
# Output (stdout, KEY=VALUE for $GITHUB_OUTPUT):
#   hub_digest=<sha256:…|absent>  ghcr_digest=<sha256:…|absent>
#   mutable_ok=yes|no   every mutable tag on both registries points at the
#                       immutable tag's digest (no when it is absent)
# Exit 1 if any registry cannot answer (registry.sh): an outage is never
# read as "absent" or "behind".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -ge 4 ] || { echo "::error::usage: release-facts.sh <tag> <hub-image> <ghcr-image> <mutable-tag>..." >&2; exit 1; }
TAG=$1 HUB=$2 GHCR=$3; shift 3

HUB_DIGEST=$(bash "$HERE/registry.sh" lookup "$HUB" "$TAG")
GHCR_DIGEST=$(bash "$HERE/registry.sh" lookup "$GHCR" "$TAG")
ok=no
if [ "$HUB_DIGEST" != absent ] && [ "$HUB_DIGEST" = "$GHCR_DIGEST" ]; then
  ok=yes
  for image in "$HUB" "$GHCR"; do
    for t in "$@"; do
      got=$(bash "$HERE/registry.sh" lookup "$image" "$t")
      if [ "$got" != "$HUB_DIGEST" ]; then
        echo "$image:$t is $got, not $HUB_DIGEST" >&2
        ok=no
      fi
    done
  done
fi
printf 'hub_digest=%s\nghcr_digest=%s\nmutable_ok=%s\n' "$HUB_DIGEST" "$GHCR_DIGEST" "$ok"
