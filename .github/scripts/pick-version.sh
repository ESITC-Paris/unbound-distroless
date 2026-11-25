#!/usr/bin/env bash
# Which version of a pinned third-party component the monitor should build
# with: the newest stable release in the SAME major line as the current pin,
# never an older one. Used by upstream-check.yml for the sidecar's vendored
# cosign (versions.env: COSIGN_VERSION).
#
# Same major only: a new major can change the CLI the sidecar drives and the
# signature formats it accepts, which is a change to make deliberately, with
# the documentation — not something to publish unattended.
# Never older: release listings are paginated and not ordered by version, so
# a partial answer could present an old release as the newest.
#
# Usage:  pick-version.sh <current X.Y.Z>     candidate tags on stdin, one per
#         line, as upstream names them (v3.1.5, 3.1.5, v3.2.0-rc.1, …)
# Output: the version to use, X.Y.Z — the current one when nothing newer in
#         its major line is listed. Anything that is not exactly [v]X.Y.Z
#         (release candidates, other tag families) is ignored.
# Exit status: 1 only when <current> is not X.Y.Z.
set -euo pipefail

CURRENT=${1:-}
[[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::pick-version.sh: '$CURRENT' is not X.Y.Z" >&2; exit 1; }
MAJOR=${CURRENT%%.*}

{ grep -oE "^v?${MAJOR}\.[0-9]+\.[0-9]+\$" || true; echo "$CURRENT"; } | sed 's/^v//' | sort -V | tail -n 1
