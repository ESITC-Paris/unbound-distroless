#!/usr/bin/env bash
# Structured logging and best-effort notifications. Never fails the caller.

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _logfmt_escape <value> — escape a value for a double-quoted logfmt field:
# backslash and double-quote (so the quoted value parses back unambiguously),
# and a literal newline (so an embedded newline can never split one log line
# into two). Anything else — including spaces — passes through unescaped.
#
# Carriage return and tab are deliberately left alone: this was considered,
# and neither can split a logfmt line the way a newline does, so escaping
# them would only make ordinary operator messages harder to read for no gain.
# A lone \r could still confuse a terminal that honours it, but these lines
# are written for log collectors and greps, not for cursor positioning.
_logfmt_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//$'\n'/\\n}"
  printf '%s' "$v"
}
_log() { printf 'ts=%s level=%s msg="%s"\n' "$(_ts)" "$1" "$(_logfmt_escape "$2")"; }

log_info()  { _log info  "$1"; }
log_warn()  { _log warn  "$1"; }
log_error() { _log error "$1" >&2; }
log_die()   { log_error "$1"; exit 1; }

# notify <event> <subject> <body>
notify() {
  local event="$1" subject="$2" body="$3"
  printf 'ts=%s level=notice event=%s subject="%s"\n' "$(_ts)" "$event" "$(_logfmt_escape "$subject")"
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
