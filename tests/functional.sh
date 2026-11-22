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
cleanup() { docker rm -f "$NAME" "$NAME-features" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A cold resolver can transiently SERVFAIL while priming (seen on CI runners
# and fresh Docker networks). Retry a dig until its output matches a pattern;
# a persistent failure still fails the gate.
retry_dig() {  # retry_dig <expected-grep-pattern> <dig args...>
  local expect="$1"; shift
  local out
  for _attempt in 1 2 3 4; do
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
for _i in $(seq 1 30); do
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
retry_dig 'status: SERVFAIL' dnssec-failed.org A >/dev/null || fail "dnssec-failed.org did not SERVFAIL"
retry_dig 'status: NOERROR' +cd dnssec-failed.org A >/dev/null \
  || fail "+cd query never returned NOERROR — cannot reach its authoritative servers or validation is not the failure cause"
pass "DNSSEC validation (bogus domain rejected, +cd bypasses)"

# 6. Cache: repeat query is answered locally (fast). The warm-up retries like
#    every live query; a cache hit needs to be observed once (a busy CI host
#    can stall one reply, it cannot make an Internet round trip take <100ms).
retry_dig 'status: NOERROR' example.com A >/dev/null || fail "cache warm-up query not NOERROR after retries"
QT=""
for _attempt in 1 2 3 4; do
  OUT=$($DIG example.com A 2>/dev/null) || OUT=""
  QT=$(echo "$OUT" | grep -oE 'Query time: [0-9]+' | grep -oE '[0-9]+' || true)
  [ -n "$QT" ] && [ "$QT" -lt 100 ] && break
  sleep 1
done
[ -n "$QT" ] || fail "cached query got no answer"
[ "$QT" -lt 100 ] || fail "cached query took ${QT}ms (expected <100ms)"
pass "cache hit (${QT}ms)"

# 7. Control channel over unix socket (exec form — no shell in image)
docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf status \
  | grep -q 'is running' || fail "unbound-control status failed"
pass "unbound-control status via unix socket"

# 7a. Compiled capabilities: DoH (nghttp2), shared cache (cachedb+hiredis),
#     EDNS Client Subnet (subnetcache) and dnstap.
CAPS=$(docker exec "$NAME" /usr/local/sbin/unbound -V)
echo "$CAPS" | grep -q -- '--with-libnghttp2' || fail "unbound not built with libnghttp2 (DoH)"
echo "$CAPS" | grep -q -- '--enable-cachedb' || fail "unbound not built with cachedb"
echo "$CAPS" | grep -q -- '--with-libhiredis' || fail "unbound not built with libhiredis (Redis/Valkey)"
echo "$CAPS" | grep -q -- '--enable-subnet' || fail "unbound not built with --enable-subnet (ECS)"
echo "$CAPS" | grep -q -- '--enable-dnstap' || fail "unbound not built with --enable-dnstap"
echo "$CAPS" | grep -E '^Linked modules:' | grep -qw 'subnetcache' || fail "subnetcache module not linked"
# Inverse guard: the library harvest is ldd-based and cannot see dlopen()'d
# objects. These modules load libraries at runtime via dlopen, so enabling
# them without extending the harvest would ship an image that breaks only
# when the feature is first used. Fail loudly here instead.
echo "$CAPS" | grep -q -- '--with-pythonmodule' && fail "pythonmodule enabled but the ldd harvest cannot ship its dlopen deps" || true
echo "$CAPS" | grep -q -- '--with-dynlibmodule' && fail "dynlibmodule enabled but the ldd harvest cannot ship its dlopen deps" || true
pass "DoH + cachedb/Redis + subnet + dnstap compiled in (dlopen-based modules confirmed off)"

# 7a-bis. The new features are opt-in: with the shipped configuration the
#     module stack is unchanged and an ECS option from a client is neither
#     used nor echoed (RFC 7871 behaviour only starts once subnetcache is in
#     module-config). dnstap is off unless dnstap-enable is set.
MODS=$(docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf get_option module-config)
[ "$MODS" = "validator iterator" ] || fail "shipped module-config changed: '$MODS'"
OUT=$(retry_dig 'status: NOERROR' +subnet=192.0.2.0/24 example.com A) || fail "query with an ECS option not NOERROR after retries"
echo "$OUT" | grep -q 'CLIENT-SUBNET' && fail "ECS echoed although subnetcache is not configured" || true
DT=$(docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf get_option dnstap-enable)
[ "$DT" = "no" ] || fail "dnstap enabled by default: '$DT'"
# ...and when configured, both actually start in this build: a build without
# subnet rejects the module, one without dnstap exits with "dnstap enabled in
# config but not built with dnstap support". Run on --network none with a
# minimal config (no collector exists, so the dnstap socket is absent: Unbound
# warns and keeps serving, which is its documented behaviour). The image runs
# as 65532, so the bind-mounted file must be world-readable.
FEAT_CONF=$(mktemp)
FEAT_NAME="$NAME-features"
chmod 0644 "$FEAT_CONF"
cat > "$FEAT_CONF" <<'EOF'
server:
  interface: 127.0.0.1
  port: 5353
  module-config: "subnetcache validator iterator"
  username: ""
  chroot: ""
  pidfile: ""
  use-syslog: no
  logfile: ""
  verbosity: 1
remote-control:
  control-enable: no
dnstap:
  dnstap-enable: yes
  dnstap-socket-path: "/run/unbound/dnstap.sock"
  dnstap-log-client-query-messages: yes
EOF
docker run -d --name "$FEAT_NAME" --network none --cap-drop=ALL --cap-add=NET_BIND_SERVICE --security-opt no-new-privileges \
  -v "$FEAT_CONF:/etc/unbound/features.conf:ro" \
  --entrypoint /usr/local/sbin/unbound "$IMG" -d -c /etc/unbound/features.conf >/dev/null \
  || { rm -f "$FEAT_CONF"; fail "could not start the subnet + dnstap container"; }
FEAT_LOGS=""
for _i in $(seq 1 15); do
  FEAT_LOGS=$(docker logs "$FEAT_NAME" 2>&1)
  grep -q 'start of service' <<<"$FEAT_LOGS" && break
  sleep 1
done
docker rm -f "$FEAT_NAME" >/dev/null 2>&1 || true
rm -f "$FEAT_CONF"
grep -q 'init module 0: subnetcache' <<<"$FEAT_LOGS" || fail "subnetcache module did not initialise: $FEAT_LOGS"
grep -q 'dnstap Message/CLIENT_QUERY enabled' <<<"$FEAT_LOGS" || fail "dnstap did not initialise: $FEAT_LOGS"
grep -q 'start of service' <<<"$FEAT_LOGS" || fail "Unbound with subnet + dnstap did not start: $FEAT_LOGS"
pass "subnet + dnstap inert with the shipped config, initialise when configured"

# 7b. Hyperlocal root zone (RFC 8806) is loaded with a real serial
docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf list_auth_zones \
  | grep -E '^\.\s.*serial' >/dev/null || fail "auth zone '.' not loaded (list_auth_zones)"
pass "hyperlocal root zone loaded"

# 8. No unexpected errors in logs (SERVFAIL lines are expected: test 5 plus
#    log-servfail deliberately produce them)
docker logs "$NAME" 2>&1 | grep -iE 'error|fatal' | grep -v 'SERVFAIL' \
  && fail "unexpected errors found in container logs" || true
pass "clean logs"

# 9. Port-53 capability behaviour under the hardening combinations people use
#    (separate script: it starts its own containers, on ephemeral ports).
bash "$(dirname "$0")/port53.sh" "$IMG" || fail "port-53 behaviour tests failed"

echo "ALL FUNCTIONAL TESTS PASSED"
