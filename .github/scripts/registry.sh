#!/usr/bin/env bash
# Read-only registry lookups with a three-way answer: a tag is present, it is
# absent, or the lookup failed. Used by release.yml and updater.yml (refuse to
# re-publish an immutable X.Y.Z-rN tag) and by upstream-check.yml (resolve the
# digest of the published `latest` to rescan it).
#
# Why not `docker buildx imagetools inspect`: it reports "not found", "rate
# limited", "registry down" and "auth refused" all as a non-zero exit, and
# telling them apart means parsing error text. A release guard that read an
# outage as "absent" would re-publish an immutable tag. Here only an HTTP 200
# (present) or 404 (absent) on the manifest is an answer; anything else —
# including a token request that fails — is an error, and the caller fails.
#
# Usage: registry.sh state  <image> <tag>   prints present | absent
#        registry.sh digest <image> <tag>   prints sha256:… (absent is an error)
#        registry.sh lookup <image> <tag>   prints sha256:… or absent
# <image>: a Docker Hub name (esitcparis/unbound-distroless) or
#          ghcr.io/<owner>/<name>. Anonymous pull tokens: both are public.
# Exit status: 0 with an answer, 1 on any error (reason on stderr).
set -euo pipefail

die() { echo "::error::registry.sh: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: registry.sh state|digest|lookup <image> <tag>"
MODE=$1 IMAGE=$2 TAG=$3
case "$MODE" in state|digest|lookup) ;; *) die "unknown mode '$MODE'" ;; esac

# Strict character sets: both values end up in URLs.
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "invalid tag '$TAG'"
case "$IMAGE" in
  ghcr.io/*)
    REPO=${IMAGE#ghcr.io/}
    TOKEN_URL="https://ghcr.io/token?scope=repository:$REPO:pull"
    API="https://ghcr.io/v2/$REPO" ;;
  *.*/*) die "unsupported registry in '$IMAGE' (Docker Hub or ghcr.io only)" ;;
  */*)
    REPO=${IMAGE#docker.io/}
    TOKEN_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull"
    API="https://registry-1.docker.io/v2/$REPO" ;;
  *) die "image '$IMAGE' must be <namespace>/<name>" ;;
esac
[[ "$REPO" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)+$ ]] || die "invalid repository '$REPO'"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --retry covers the transient answers (408, 429, 5xx); a 404 is not retried.
curl -fsS -m 30 --retry 3 --retry-delay 5 -o "$TMP/token.json" "$TOKEN_URL" \
  || die "token request for $REPO failed"
TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$TMP/token.json" 2>/dev/null) \
  || die "token response for $REPO is not usable"
[ -n "$TOKEN" ] || die "empty token for $REPO"

# HEAD, never GET: Docker Hub does not count HEAD requests against the
# anonymous pull rate limit. Index and manifest types both accepted so the
# digest returned is the one a client pulling the tag would get.
CODE=$(curl -sS -m 30 --retry 3 --retry-delay 5 -I -o /dev/null -D "$TMP/headers" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "$API/manifests/$TAG") || CODE=000

case "$CODE" in
  200) ;;
  404)
    [ "$MODE" = digest ] || { echo absent; exit 0; }
    die "$IMAGE:$TAG does not exist" ;;
  *) die "manifest lookup for $IMAGE:$TAG answered HTTP $CODE — neither present nor absent" ;;
esac

if [ "$MODE" = state ]; then echo present; exit 0; fi
DIGEST=$(tr -d '\r' < "$TMP/headers" | awk 'tolower($1)=="docker-content-digest:" {print $2}' | tail -1)
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no usable Docker-Content-Digest for $IMAGE:$TAG (got '$DIGEST')"
echo "$DIGEST"
