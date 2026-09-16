#!/usr/bin/env bash
# Resolver readiness and correctness checks. The SAME function gates the
# canary and the post-swap production container: whatever was judged good on
# the canary is exactly what production is held to.

VALIDATE_DOMAIN="${VALIDATE_DOMAIN:-example.com}"
STRICT_BOGUS_CHECK="${STRICT_BOGUS_CHECK:-0}"
# REQUIRE_DNSSEC=0 waives the AD-flag criterion for a resolver deliberately
# run without the validator (a forwarder to an internal, unsigned upstream).
# Read at call time, not at source time, so a caller can override it per call.

# wait_resolver <ip> [timeout_seconds]
# A DNS query of our own, NOT the image HEALTHCHECK: that healthcheck talks to
# the unix control socket, which a user's configuration may legitimately
# replace with a TCP/TLS remote-control — and a resolver that answers queries
# is exactly what we care about.
wait_resolver() {
  local ip="$1" timeout="${2:-60}" deadline
  deadline=$(( $(date -u +%s) + timeout ))
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    if dig +time=2 +tries=1 "@$ip" "$VALIDATE_DOMAIN" A 2>/dev/null | grep -q 'status: NOERROR'; then
      return 0
    fi
    sleep 2
  done
  log_error "resolver at $ip did not answer within ${timeout}s"
  return 1
}

# _retry_dig <expected-ERE> <dig args…> — a cold resolver can transiently
# SERVFAIL while priming; a persistent failure still fails the gate.
_retry_dig() {
  local expect="$1" out; shift
  local _attempt
  for _attempt in 1 2 3 4; do
    out=$(dig +time=5 +tries=2 "$@" 2>/dev/null) || out=""
    grep -qE "$expect" <<<"$out" && return 0
    sleep 5
  done
  return 1
}

# validate_resolver <ip>
validate_resolver() {
  local ip="$1"
  _retry_dig 'status: NOERROR'    "@$ip" "$VALIDATE_DOMAIN" A      || { log_error "validation: UDP resolution failed"; return 1; }
  _retry_dig 'status: NOERROR'    "@$ip" +tcp "$VALIDATE_DOMAIN" A || { log_error "validation: TCP resolution failed"; return 1; }
  if [ "${REQUIRE_DNSSEC:-1}" = 1 ]; then
    _retry_dig '^;; flags:.* ad'  "@$ip" . SOA +dnssec             || { log_error "validation: no AD flag on the root SOA — DNSSEC validation is not working (set REQUIRE_DNSSEC=0 only if this resolver deliberately runs without the validator)"; return 1; }
  fi
  if [ "$STRICT_BOGUS_CHECK" = 1 ]; then
    _retry_dig 'status: SERVFAIL' "@$ip" dnssec-failed.org A       || { log_error "validation: a deliberately bogus domain was not rejected"; return 1; }
  fi
  return 0
}
