#!/usr/bin/env bash
# Unit test for the external trigger (deploy/unbound-upstream-check).
# Runs anywhere: no network, no docker — curl is replaced by a fake that
# records every call and answers from canned responses.
# SC2015: `A && B || fail …` is used as if-then-else on purpose — fail exits.
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/deploy/unbound-upstream-check"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
printf 'ghp_testtoken\n' > "$tmp/token"

# Fake curl. Honours -o, -D, -w, -X, -d/--data-raw and the URL; everything
# else is ignored. Canned behaviour is driven by files in $tmp:
#   dispatch_code  HTTP status of the POST (default 204)
#   id_after       run id returned by the 2nd and later run listings
#                  (default: same as before → "no run appeared")
#   expiry         value of the github-authentication-token-expiration header
#   last_success   created_at of the newest successful run (default: now);
#                  the word "none" answers with no run at all
#   success_code   HTTP status of that listing (default 200)
cat > "$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
T="$FAKE_DIR"
out=""; hdr=""; fmt=""; method=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -d|--data-raw) data="$2"; shift 2 ;;
    -H|-m|--retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$method $url $data" >> "$T/calls"
case "$url" in
  https://hc.example/*) exit 0 ;;
  */dispatches)
    code=$(cat "$T/dispatch_code" 2>/dev/null || echo 204)
    [ "$code" = 204 ] && : > "$out" || echo '{"message":"Bad credentials"}' > "$out"
    : > "$hdr"; printf '%s' "$code" ;;
  */runs\?*status=success*)
    code=$(cat "$T/success_code" 2>/dev/null || echo 200)
    at=$(cat "$T/last_success" 2>/dev/null || date -u +%FT%TZ)
    if [ "$at" = none ]; then
      printf '{"total_count": 0,\n"workflow_runs": []}\n' > "$out"
    else
      printf '{"total_count": 1,\n"workflow_runs": [{"id": 90, "name": "Upstream check", "actor": {"id": 1}, "status": "completed", "conclusion": "success", "created_at": "%s", "updated_at": "2020-01-01T00:00:00Z", "repository": {"id": 2}}]}\n' "$at" > "$out"
    fi
    : > "$hdr"; printf '%s' "$code" ;;
  */runs\?*)
    n=$(( $(cat "$T/gets" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/gets"
    id=100; [ "$n" -gt 1 ] && id=$(cat "$T/id_after" 2>/dev/null || echo 100)
    printf '{"total_count": 7,\n"workflow_runs": [{"id": %s, "name": "Upstream check", "actor": {"id": 1}}]}\n' "$id" > "$out"
    { printf 'HTTP/2 200\r\n'; [ -f "$T/expiry" ] && printf 'github-authentication-token-expiration: %s\r\n' "$(cat "$T/expiry")"; printf '\r\n'; } > "$hdr"
    printf 200 ;;
  *) echo "fake curl: unexpected url $url" >&2; exit 99 ;;
esac
FAKE
chmod +x "$tmp/bin/curl"

run() {  # run [VAR=value...] → stdout+stderr in $out, exit code in $rc; resets the fakes
  rm -f "$tmp/calls" "$tmp/gets"
  rc=0
  out=$(env PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" UNBOUND_TRIGGER_CONF=/nonexistent \
        TOKEN_FILE="$tmp/token" HC_URL=https://hc.example/abc REPO=org/repo \
        STATE_DIR="$tmp/state" POLL_ATTEMPTS=2 POLL_INTERVAL=0 "$@" \
        bash "$SCRIPT" 2>&1) || rc=$?
}
calls() { cat "$tmp/calls"; }

# 1. Happy path: dispatch accepted, a new run appears, silent, HC success.
echo 101 > "$tmp/id_after"
run
[ "$rc" = 0 ] || fail "happy path exit $rc: $out"
[ -z "$out" ] || fail "happy path must be silent on success: $out"
calls | grep -q '^POST https://api.github.com/repos/org/repo/actions/workflows/upstream-check.yml/dispatches {"ref":"main"}$' \
  || fail "dispatch call missing or wrong: $(calls)"
calls | grep -q '^GET https://hc.example/abc/start' || fail "no /start ping: $(calls)"
calls | grep -q '^GET https://hc.example/abc run 101 started$' || fail "no success ping with the run id: $(calls)"
calls | grep -q 'hc.example/abc/fail' && fail "unexpected /fail ping: $(calls)"
pass "dispatch → run 101 confirmed → Healthchecks success, silent"

# 2. Dispatch refused (expired or revoked token): loud failure, /fail ping,
#    nothing is confirmed.
echo 401 > "$tmp/dispatch_code"
run
[ "$rc" = 1 ] || fail "401 must exit 1, got $rc: $out"
grep -q 'dispatch failed (HTTP 401)' <<<"$out" || fail "401 message: $out"
calls | grep -q '^GET https://hc.example/abc/fail dispatch failed (HTTP 401)' || fail "no /fail ping: $(calls)"
pass "HTTP 401 → exit 1, reason on stderr and in the /fail ping"
rm -f "$tmp/dispatch_code"

# 3. Accepted but no run shows up (workflow disabled): that is a failure too.
rm -f "$tmp/id_after"
run
[ "$rc" = 1 ] || fail "no-run must exit 1, got $rc: $out"
grep -q 'no new run of upstream-check.yml appeared' <<<"$out" || fail "no-run message: $out"
calls | grep -q 'hc.example/abc/fail' || fail "no /fail ping on no-run: $(calls)"
pass "204 but no run appears → exit 1 (a 204 is not a started run)"
echo 101 > "$tmp/id_after"

# 4. Token expiring soon: warned once a day on stderr, still exit 0.
date -u -d '+10 days' '+%F %T UTC' > "$tmp/expiry"
run
[ "$rc" = 0 ] || fail "expiry warning must not fail, got $rc: $out"
grep -q 'token expires in 9 day(s)\|token expires in 10 day(s)' <<<"$out" || fail "expiry warning missing: $out"
calls | grep -q '^GET https://hc.example/abc run 101 started; token expires in' || fail "expiry note missing from success ping: $(calls)"
run
[ "$rc" = 0 ] || fail "second run exit $rc: $out"
[ -z "$out" ] || fail "expiry warning must be printed once a day, got: $out"
pass "token expiring in 10 days → one stderr warning per day, exit 0"

# 5. Token about to expire: the dispatch still happens, then the run fails.
date -u -d '+1 day' '+%F %T UTC' > "$tmp/expiry"
run
[ "$rc" = 1 ] || fail "imminent expiry must exit 1, got $rc: $out"
grep -q 'renew it now' <<<"$out" || fail "imminent expiry message: $out"
calls | grep -q '/dispatches' || fail "dispatch must still happen before failing on expiry: $(calls)"
calls | grep -q 'hc.example/abc/fail' || fail "no /fail ping on imminent expiry: $(calls)"
pass "token expiring in 1 day → dispatch, then exit 1 with /fail"
rm -f "$tmp/expiry"

# 6. Missing token file: loud failure before touching the API.
TOKEN_SAVE="$tmp/token"; mv "$tmp/token" "$tmp/token.gone"
run
[ "$rc" = 1 ] || fail "missing token must exit 1, got $rc: $out"
grep -q 'token file .* is missing' <<<"$out" || fail "missing token message: $out"
calls | grep -q 'api.github.com' && fail "API must not be called without a token: $(calls)"
mv "$tmp/token.gone" "$TOKEN_SAVE"
pass "missing token file → exit 1, API untouched"

# 7. Runs start but none has succeeded for hours: the monitor does nothing,
#    and this is the alarm that does not depend on the workflow's own issues.
date -u -d '-2 hours' +%FT%TZ > "$tmp/last_success"
run
[ "$rc" = 0 ] && [ -z "$out" ] || fail "a success 2 h ago is within the default 3 h: rc=$rc $out"
date -u -d '-200 minutes' +%FT%TZ > "$tmp/last_success"
run
[ "$rc" = 1 ] || fail "no success for 3 h must exit 1, got $rc: $out"
grep -q 'no run of upstream-check.yml has succeeded for 3 h' <<<"$out" || fail "stale-success message: $out"
calls | grep -q '/dispatches' || fail "the dispatch must still happen before failing on a stale success: $(calls)"
calls | grep -q '^GET https://hc.example/abc/fail run 101 started, but no run' || fail "no /fail ping on a stale success: $(calls)"
calls | grep -q '^GET https://hc.example/abc run 101 started' && fail "a success ping was sent despite the stale success: $(calls)"
run MAX_SUCCESS_AGE_HOURS=6
[ "$rc" = 0 ] || fail "MAX_SUCCESS_AGE_HOURS=6 must accept a success 3 h 20 ago: rc=$rc $out"
run MAX_SUCCESS_AGE_HOURS=0
[ "$rc" = 0 ] || fail "MAX_SUCCESS_AGE_HOURS=0 disables the check: rc=$rc $out"
calls | grep -q 'status=success' && fail "the check is disabled but the listing was still requested: $(calls)"
echo none > "$tmp/last_success"
run
[ "$rc" = 1 ] && grep -q 'has no successful run at all' <<<"$out" || fail "no successful run at all must exit 1: rc=$rc $out"
echo 'last tuesday-ish' > "$tmp/last_success"
run
[ "$rc" = 1 ] && grep -q 'unreadable' <<<"$out" || fail "an unreadable date must exit 1, not pass: rc=$rc $out"
rm -f "$tmp/last_success"; echo 502 > "$tmp/success_code"
run
[ "$rc" = 1 ] && grep -q 'listing the successful runs failed (HTTP 502)' <<<"$out" || fail "a failed listing must exit 1, not pass: rc=$rc $out"
rm -f "$tmp/success_code"
run MAX_SUCCESS_AGE_HOURS=soon
[ "$rc" = 1 ] && ! calls | grep -q '/dispatches' || fail "a bad MAX_SUCCESS_AGE_HOURS must be refused before anything is done: rc=$rc $out"
pass "no successful run for MAX_SUCCESS_AGE_HOURS (or none, or an unreadable answer) → dispatch, then exit 1 with /fail"

# 8. No Healthchecks URL: the script works, and says once a day that nothing
#    watches it.
rm -rf "$tmp/state"; mkdir "$tmp/state"
run HC_URL=
[ "$rc" = 0 ] || fail "an empty HC_URL must not fail the run: rc=$rc $out"
grep -q 'HC_URL is not set' <<<"$out" || fail "an empty HC_URL must be said on stderr: $out"
calls | grep -q 'hc.example' && fail "pings were sent without HC_URL: $(calls)"
run HC_URL=
[ "$rc" = 0 ] && [ -z "$out" ] || fail "the HC_URL warning must be printed once a day: rc=$rc $out"
pass "no HC_URL → one stderr warning per day, exit 0"

echo "ALL TRIGGER TESTS PASSED"
