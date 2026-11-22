#!/bin/sh
# Build the resolver image locally with exactly the pins CI uses:
#   versions.env       -> UNBOUND_VERSION, UNBOUND_SHA256, IMAGE_REVISION (X.Y.Z-rN)
#   .build-state.json  -> DEBIAN_BASE, DISTROLESS_BASE (by digest)
# A bare `docker build` uses floating base tags instead and is not
# reproducible (see the top of the Dockerfile).
#
# Usage: scripts/build.sh [image-tag] [extra docker build args...]
#   scripts/build.sh                                   # -> unbound-distroless:test
#   scripts/build.sh myresolver:dev --platform linux/amd64 --no-cache
# The default tag is the one tests/structure.sh and tests/functional.sh use.
#
# POSIX sh and sed only, on purpose: no python/jq, so it runs unchanged on a
# Linux runner, macOS and a minimal container.
set -eu

# The base image names must stay identical to the ones the workflows pin
# (.github/workflows/ci.yml and release.yml, "Load pinned base image digests").
DEBIAN_REPO=debian:trixie
DISTROLESS_REPO=gcr.io/distroless/base-debian13:nonroot

die() { echo "build.sh: $*" >&2; exit 1; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

TAG=${1:-unbound-distroless:test}
[ "$#" -gt 0 ] && shift

[ -f versions.env ] || die "versions.env not found in $ROOT"
[ -f .build-state.json ] || die ".build-state.json not found in $ROOT"

# versions.env is read as data (KEY=VALUE), not sourced: nothing in it runs.
env_value() {
  v=$(sed -n "s/^$1=//p" versions.env | tail -n 1)
  [ -n "$v" ] || die "$1 missing from versions.env"
  printf '%s\n' "$v"
}

# .build-state.json is flat {"key": "sha256:<64 hex>", ...}; take one digest
# and refuse anything that is not exactly a sha256 digest.
state_digest() {
  d=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\(sha256:[0-9a-f]\{64\}\)\".*/\1/p" .build-state.json | head -n 1)
  [ -n "$d" ] || die "no sha256 digest for \"$1\" in .build-state.json"
  printf '%s\n' "$d"
}

UNBOUND_VERSION=$(env_value UNBOUND_VERSION)
UNBOUND_SHA256=$(env_value UNBOUND_SHA256)
REVISION=$(env_value REVISION)

printf '%s\n' "$UNBOUND_VERSION" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' \
  || die "UNBOUND_VERSION '$UNBOUND_VERSION' is not X.Y.Z"
printf '%s\n' "$UNBOUND_SHA256" | grep -Eqx '[0-9a-f]{64}' \
  || die "UNBOUND_SHA256 is not 64 hex characters"
printf '%s\n' "$REVISION" | grep -Eqx '[0-9]+' \
  || die "REVISION '$REVISION' is not a number"

IMAGE_REVISION="${UNBOUND_VERSION}-r${REVISION}"
DEBIAN_BASE="${DEBIAN_REPO}@$(state_digest debian)"
DISTROLESS_BASE="${DISTROLESS_REPO}@$(state_digest distroless)"

echo "build.sh: $TAG = unbound $IMAGE_REVISION"
echo "build.sh:   DEBIAN_BASE=$DEBIAN_BASE"
echo "build.sh:   DISTROLESS_BASE=$DISTROLESS_BASE"

exec docker build \
  --build-arg "UNBOUND_VERSION=$UNBOUND_VERSION" \
  --build-arg "UNBOUND_SHA256=$UNBOUND_SHA256" \
  --build-arg "DEBIAN_BASE=$DEBIAN_BASE" \
  --build-arg "DISTROLESS_BASE=$DISTROLESS_BASE" \
  --build-arg "IMAGE_REVISION=$IMAGE_REVISION" \
  --tag "$TAG" \
  "$@" \
  .
