#!/usr/bin/env bash
# Structured logging and best-effort notifications. Never fails the caller.

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf 'ts=%s level=%s msg=%s\n' "$(_ts)" "$1" "$(printf '%q' "$2")"; }

log_info()  { _log info  "$1"; }
log_warn()  { _log warn  "$1"; }
log_error() { _log error "$1" >&2; }
log_die()   { log_error "$1"; exit 1; }

# notify <event> <subject> <body>
notify() {
  local event="$1" subject="$2" body="$3"
  printf 'ts=%s level=notice event=%s subject=%s\n' "$(_ts)" "$event" "$(printf '%q' "$subject")"
  [ -n "${WEBHOOK_URL:-}" ] || return 0
  local payload
  payload=$(jq -nc --arg e "$event" --arg h "$(hostname)" --arg s "$subject" --arg b "$body" \
    '{event:$e, host:$h, subject:$s, body:$b, text:("[unbound-autoupdate] " + $h + " — " + $s + "\n" + $b)}')
  curl -fsS -m 15 --retry 2 -H 'Content-Type: application/json' \
    -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 \
    || log_warn "webhook delivery failed"
}

_hc() {  # _hc <suffix> [body]
  [ -n "${HC_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 2 --data-raw "${2:-}" "${HC_URL}${1}" >/dev/null 2>&1 \
    || log_warn "healthchecks ping failed"
}
hc_start()   { _hc /start; }
hc_success() { _hc ""; }
hc_fail()    { _hc /fail "${1:-}"; }
