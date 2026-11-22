#!/usr/bin/env bash
# Release guard for release.yml and updater.yml: succeed only if the
# immutable image tag exists in NONE of the given repositories.
#
# Usage: refuse-published.sh <tag> <image>...   (images as for registry.sh)
# Env:   REBUILD_TARGET  resolver | sidecar — named in the recovery hint
#
# Fails closed: a registry that cannot answer "present" or "absent" (outage,
# rate limit, auth refusal) stops the release exactly like a present tag.
# A release that failed before pushing the immutable tag can therefore be
# re-dispatched as is; one that failed after (signing, attestation) cannot,
# and the recovery is a new revision.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ $# -ge 2 ] || { echo "::error::usage: refuse-published.sh <tag> <image>..." >&2; exit 1; }
TAG=$1; shift
present=""
for image in "$@"; do
  if ! state=$(bash "$HERE/registry.sh" state "$image" "$TAG"); then
    echo "::error::cannot tell whether $image:$TAG exists (see above) — refusing to publish until the registry answers; re-dispatch later" >&2
    exit 1
  fi
  echo "$image:$TAG: $state"
  [ "$state" = absent ] || present="$present $image:$TAG"
done

if [ -n "$present" ]; then
  echo "::error::already published:$present. An X.Y.Z-rN tag is never re-pushed. If an earlier run of this tag failed after pushing it (signing, attestation), publish a new revision instead: gh workflow run upstream-check.yml -f rebuild=${REBUILD_TARGET:-<resolver|sidecar>}" >&2
  exit 1
fi
