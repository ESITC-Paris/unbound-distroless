#!/usr/bin/env bash
# Structure tests: verify image invariants without running the daemon.
# Usage: tests/structure.sh [image-tag]
set -euo pipefail

IMG="${1:-unbound-distroless:test}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v docker >/dev/null || fail "docker not found"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "image $IMG not found — build it first"

# 1. Runs as nonroot
USERCFG=$(docker image inspect -f '{{.Config.User}}' "$IMG")
[ "$USERCFG" = "nonroot" ] || [ "$USERCFG" = "65532" ] || [ "$USERCFG" = "65532:65532" ] \
  || fail "image user is '$USERCFG', expected nonroot/65532"
pass "runs as nonroot ($USERCFG)"

# 2. Entrypoint and healthcheck
EP=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$IMG")
echo "$EP" | grep -q '/usr/local/sbin/unbound' || fail "unexpected entrypoint: $EP"
HC=$(docker image inspect -f '{{json .Config.Healthcheck}}' "$IMG")
echo "$HC" | grep -q 'unbound-control' || fail "healthcheck missing or wrong: $HC"
pass "entrypoint + healthcheck configured"

# 3. Exposed ports
PORTS=$(docker image inspect -f '{{json .Config.ExposedPorts}}' "$IMG")
echo "$PORTS" | grep -q '53/udp' || fail "53/udp not exposed"
echo "$PORTS" | grep -q '53/tcp' || fail "53/tcp not exposed"
pass "port 53 exposed (udp+tcp)"

# 4. Filesystem contents via export (image has no shell to exec into)
CID=$(docker create "$IMG")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
LIST=$(docker export "$CID" | tar -tf -)

# Feed $LIST via a here-string, not a pipe: `grep -q` exits at the first match,
# which kills `echo` with SIGPIPE, and `set -o pipefail` then turns a successful
# match into a spurious failure whenever the match is early enough in the list.
must_have() { grep -qE "$1" <<<"$LIST" || fail "missing from image: $1"; }
must_not_have() { grep -qE "$1" <<<"$LIST" && fail "must NOT be in image: $1" || true; }

must_have '^usr/local/sbin/unbound$'
must_have '^usr/local/sbin/unbound-control$'
must_have '^usr/local/sbin/unbound-anchor$'
must_have '^usr/local/sbin/unbound-checkconf$'
must_have '^etc/unbound/unbound.conf$'
must_have '^etc/unbound/root.hints$'
must_have '^var/lib/unbound/root.key$'
must_have '^var/lib/unbound/root.zone$'
must_have '^run/unbound/$'
must_have '^etc/ssl/certs/ca-certificates.crt$'
# Harvested runtime libs live in the multiarch triplet dir (usr/lib/<triplet>/),
# which is where the ELF interpreter path resolves and the first default search
# dir — so the harvested loader and libc replace the base's as one coherent set.
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libevent'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libnghttp2'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libhiredis'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libc\.so\.6$'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/ld-linux-'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libunbound\.so\.8$'
must_have '^var/lib/dpkg/status.d/'
pass "expected files present"

# No stale flat copies shadowed by / shadowing the triplet dir, and no dpkg
# diversion junk. (usr/lib/ld-linux-* may legitimately exist as the base's
# symlink into the triplet dir on arm64, so it is not checked here.)
must_not_have '^usr/lib/lib(event|c\.so\.6|crypto|ssl|expat|unbound)'
must_not_have '^var/lib/dpkg/status.d/diversion'
pass "no flat lib copies shadowing the triplet dir, no dpkg diversion junk"

# No shell, in either layout: Debian 13 is merged-/usr, so a leaked shell lands
# at usr/bin/... and `bin` is only a symlink in the tar stream.
must_not_have '^usr/bin/(sh|bash|dash)$'
must_not_have '^bin/(sh|bash|dash)$'
must_not_have '^usr/bin/apt'
must_not_have '^usr/bin/dpkg$'
must_not_have '^etc/unbound/unbound_server.key$'   # no baked-in control TLS keys
must_not_have '^etc/unbound/unbound_control.key$'
pass "no shell, no package manager, no baked-in private keys"

echo "ALL STRUCTURE TESTS PASSED"
