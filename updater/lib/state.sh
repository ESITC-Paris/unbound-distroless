#!/usr/bin/env bash
# Persistent state, advisory lock and digest quarantine.
# STATE_DIR must be a writable named volume so state survives recreation.

STATE_DIR="${STATE_DIR:-/var/lib/unbound-autoupdate}"
STATE_FILE="$STATE_DIR/state.env"
# Consumed by callers that source this library (the orchestrator's flock use,
# added in a later task); shellcheck cannot see that from this file alone.
# shellcheck disable=SC2034
LOCK_FILE="$STATE_DIR/lock"

state_init() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
}

# state_get <key> — echoes the value, or nothing when unset.
state_get() {
  local line
  line=$(grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null) || return 0
  printf '%s\n' "${line#*=}"
}

# state_set <key> <value> — atomic replace-or-append.
state_set() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
  grep -v "^$key=" "$STATE_FILE" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

quarantine_set() {
  state_set QUARANTINE_DIGEST "$1"
  state_set QUARANTINE_TS "$(date -u +%s)"
}

quarantine_clear() {
  state_set QUARANTINE_DIGEST ""
  state_set QUARANTINE_TS ""
}

# quarantine_active <digest> — returns 0 when this digest is quarantined and
# the RETRY_AFTER window has not elapsed. A different digest is never
# quarantined: a newly published image deserves a fresh attempt.
quarantine_active() {
  local d ts now
  d=$(state_get QUARANTINE_DIGEST)
  [ -n "$d" ] && [ "$d" = "$1" ] || return 1
  ts=$(state_get QUARANTINE_TS); [ -n "$ts" ] || return 1
  now=$(date -u +%s)
  [ $(( now - ts )) -lt "$(to_seconds "${RETRY_AFTER:-24h}")" ]
}

# to_seconds <duration> — 45s | 30m | 1h | 2d | bare integer (seconds).
to_seconds() {
  local v="$1" n u
  n="${v%[smhd]}"; u="${v##"$n"}"
  case "$n" in ''|*[!0-9]*) log_die "invalid duration: $v";; esac
  case "$u" in
    ''|s) printf '%s\n' "$n" ;;
    m)    printf '%s\n' $(( n * 60 )) ;;
    h)    printf '%s\n' $(( n * 3600 )) ;;
    d)    printf '%s\n' $(( n * 86400 )) ;;
    *)    log_die "invalid duration suffix: $v" ;;
  esac
}
