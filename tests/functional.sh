#!/usr/bin/env bash
# Functional tests: run the image with production hardening flags and verify
# real DNS resolution, DNSSEC validation, caching, control channel, health.
# Usage: tests/functional.sh [image-tag]
set -euo pipefail

IMG="${1:-unbound-distroless:test}"
NAME="unbound-func-test-$$"
PORT=5533
DIG="dig @127.0.0.1 -p $PORT +time=5 +tries=2"

fail() { echo "FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -20 || true; exit 1; }
pass() { echo "PASS: $*"; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A cold resolver can transiently SERVFAIL while priming (seen on CI runners
# and fresh Docker networks). Retry a dig until its output matches a pattern;
# a persistent failure still fails the gate.
retry_dig() {  # retry_dig <expected-grep-pattern> <dig args...>
  local expect="$1"; shift
  local out
  for attempt in 1 2 3 4; do
    out=$($DIG "$@" 2>/dev/null) || out=""
    if echo "$out" | grep -qE "$expect"; then echo "$out"; return 0; fi
    sleep 5
  done
  echo "$out"
  return 1
}

command -v dig >/dev/null || fail "dig not found (install bind9-dnsutils / dnsutils)"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "image $IMG not found — build it first"

# Start with the documented production hardening flags.
docker run -d --name "$NAME" \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  -p 127.0.0.1:$PORT:53/udp -p 127.0.0.1:$PORT:53/tcp \
  "$IMG" >/dev/null

# 1. Container reaches healthy state
for i in $(seq 1 30); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)
  [ "$STATUS" = "healthy" ] && break
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ] || fail "container exited"
  sleep 2
done
[ "$STATUS" = "healthy" ] || fail "container never became healthy (status: $STATUS)"
pass "container healthy"

# 2. Recursive resolution over UDP
OUT=$(retry_dig 'status: NOERROR' example.com A) || fail "UDP query not NOERROR after retries"
echo "$OUT" | grep -qE 'ANSWER: [1-9]' || fail "UDP query returned no answers"
pass "recursive resolution (UDP)"

# 3. Resolution over TCP (example.com is already cached from test 2 — this
#    exercises the TCP listener without depending on another TLD walk, which
#    proved unreliable from CI runner networks)
retry_dig 'status: NOERROR' +tcp example.com A >/dev/null || fail "TCP query not NOERROR after retries"
pass "resolution over TCP"

# 4. DNSSEC: validated answer carries the AD flag (root SOA is always signed)
retry_dig '^;; flags:.* ad' . SOA +dnssec >/dev/null || fail "no AD flag on root SOA — DNSSEC validation broken"
pass "DNSSEC validation (AD flag)"

# 5. DNSSEC: a deliberately broken domain must SERVFAIL, and succeed with +cd
OUT=$($DIG dnssec-failed.org A) || true
echo "$OUT" | grep -q 'status: SERVFAIL' || fail "dnssec-failed.org did not SERVFAIL"
retry_dig 'status: NOERROR' +cd dnssec-failed.org A >/dev/null \
  || fail "+cd query never returned NOERROR — cannot reach its authoritative servers or validation is not the failure cause"
pass "DNSSEC validation (bogus domain rejected, +cd bypasses)"

# 6. Cache: repeat query is answered locally (fast)
$DIG example.com A >/dev/null
OUT=$($DIG example.com A)
QT=$(echo "$OUT" | grep -oE 'Query time: [0-9]+' | grep -oE '[0-9]+')
[ "$QT" -lt 100 ] || fail "cached query took ${QT}ms (expected <100ms)"
pass "cache hit (${QT}ms)"

# 7. Control channel over unix socket (exec form — no shell in image)
docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf status \
  | grep -q 'is running' || fail "unbound-control status failed"
pass "unbound-control status via unix socket"

# 7a. Compiled capabilities: DoH (nghttp2) and shared cache (cachedb+hiredis)
CAPS=$(docker exec "$NAME" /usr/local/sbin/unbound -V)
echo "$CAPS" | grep -q -- '--with-libnghttp2' || fail "unbound not built with libnghttp2 (DoH)"
echo "$CAPS" | grep -q -- '--enable-cachedb' || fail "unbound not built with cachedb"
echo "$CAPS" | grep -q -- '--with-libhiredis' || fail "unbound not built with libhiredis (Redis/Valkey)"
pass "DoH + cachedb/Redis capabilities compiled in"

# 7b. Hyperlocal root zone (RFC 8806) is loaded with a real serial
docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf list_auth_zones \
  | grep -E '^\.\s.*serial' >/dev/null || fail "auth zone '.' not loaded (list_auth_zones)"
pass "hyperlocal root zone loaded"

# 8. No unexpected errors in logs (SERVFAIL lines are expected: test 5 plus
#    log-servfail deliberately produce them)
docker logs "$NAME" 2>&1 | grep -iE 'error|fatal' | grep -v 'SERVFAIL' \
  && fail "unexpected errors found in container logs" || true
pass "clean logs"

echo "ALL FUNCTIONAL TESTS PASSED"
