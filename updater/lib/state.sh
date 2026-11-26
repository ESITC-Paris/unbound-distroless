#!/usr/bin/env bash
# Persistent state, advisory lock and digest quarantine.
# STATE_DIR must be a writable named volume so state survives recreation.

STATE_DIR="${STATE_DIR:-/var/lib/unbound-autoupdate}"
STATE_FILE="$STATE_DIR/state.env"
# Consumed by callers that source this library (the orchestrator's flock use,
# added in a later task); shellcheck cannot see that from this file alone.
# shellcheck disable=SC2034
LOCK_FILE="$STATE_DIR/lock"
# The transient Compose override the rollback path writes. Named here rather
# than inline at its one use site because discover.sh must also recognise it,
# to keep it OUT of the discovered compose file list (see there).
# shellcheck disable=SC2034
ROLLBACK_FILE="$STATE_DIR/rollback.yml"

# The self-update helper's own override (Task 5), excluded from the compose
# file list exactly like ROLLBACK_FILE.
# shellcheck disable=SC2034
SELF_ROLLBACK_FILE="$STATE_DIR/self-rollback.yml"

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

# state_set <key> <value> — replace-or-append, atomically or not at all.
#
# The new file is checked before it replaces the old one: it must hold every
# other line of the current state plus this key's, complete. On a full volume
# the copy used to come out short or empty, went unnoticed (the write's status
# was discarded), and was then moved over state.env — taking the quarantines,
# the deployed image and configuration fingerprints and an unfinished swap's
# intent with it, so the next cycle adopted whatever was running as its
# baseline without a canary. Now a write that cannot be completed leaves
# state.env exactly as it was and returns 1: under the cycle's `set -e` that
# ends the cycle as an error, before anything is deployed on a state that
# could not be recorded.
state_set() {
  local key="$1" value="$2" tmp kept=0 written
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX" 2>/dev/null) \
    || { log_error "state: cannot create a file in $STATE_DIR (volume full or read-only?) — $key not recorded, previous state kept"; return 1; }
  if [ -s "$STATE_FILE" ]; then
    # grep -c prints the count and exits 1 when it is 0: not an error here.
    kept=$(grep -vc "^$key=" "$STATE_FILE" 2>/dev/null) || true
    grep -v "^$key=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp" 2>/dev/null || true
  written=$(wc -l < "$tmp" 2>/dev/null) || written=""
  if [ "${written:-x}" != "$(( ${kept:-0} + 1 ))" ] || [ "$(tail -n 1 "$tmp" 2>/dev/null)" != "$key=$value" ]; then
    rm -f "$tmp"
    log_error "state: could not write $STATE_FILE completely (volume full?) — $key not recorded, previous state kept"
    return 1
  fi
  mv -f "$tmp" "$STATE_FILE"
}

# state_inc <key> — increment an integer counter (unset counts as 0).
state_inc() {
  local cur; cur=$(state_get "$1"); : "${cur:=0}"
  state_set "$1" $(( cur + 1 ))
}

# Three quarantine axes share one mechanism, keyed on what changed:
#   image  — QUARANTINE_DIGEST / QUARANTINE_TS          (a resolver image)
#   config — CONFIG_QUARANTINE_HASH / CONFIG_QUARANTINE_TS (a config fingerprint)
#   self   — SELF_QUARANTINE_DIGEST / SELF_QUARANTINE_TS  (a sidecar image)
# A quarantined value is not retried before RETRY_AFTER elapses; a DIFFERENT
# value on the same axis always gets a fresh attempt. A config-only failure
# has no image worth quarantining, and a broken sidecar image must not block
# resolver updates: hence separate axes.
_quarantine_set()   { state_set "$1" "$3"; state_set "$2" "$(date -u +%s)"; }
_quarantine_clear() { state_set "$1" ""; state_set "$2" ""; }
# _quarantine_window_open <tskey> — 0 while the axis's timestamp is set and
# RETRY_AFTER has not elapsed, whatever value is quarantined (metrics use it).
_quarantine_window_open() {
  local ts now
  ts=$(state_get "$1"); [ -n "$ts" ] || return 1
  now=$(date -u +%s)
  [ $(( now - ts )) -lt "$(to_seconds "${RETRY_AFTER:-24h}")" ]
}
# A quarantined IMAGE is matched by its digest alone: the same image may be
# written "docker.io/esitcparis/…", "esitcparis/…" or "index.docker.io/…"
# depending on the compose file and the sidecar version that recorded it, and
# a sha256 names it unambiguously. Values without "@" (configuration
# fingerprints) compare whole.
_quarantine_active() {  # <valuekey> <tskey> <value>
  local v; v=$(state_get "$1")
  [ -n "$v" ] && [ "${v##*@}" = "${3##*@}" ] || return 1
  _quarantine_window_open "$2"
}

quarantine_set()           { _quarantine_set    QUARANTINE_DIGEST QUARANTINE_TS "$1"; }
quarantine_clear()         { _quarantine_clear  QUARANTINE_DIGEST QUARANTINE_TS; }
quarantine_active()        { _quarantine_active QUARANTINE_DIGEST QUARANTINE_TS "$1"; }
config_quarantine_set()    { _quarantine_set    CONFIG_QUARANTINE_HASH CONFIG_QUARANTINE_TS "$1"; }
config_quarantine_clear()  { _quarantine_clear  CONFIG_QUARANTINE_HASH CONFIG_QUARANTINE_TS; }
config_quarantine_active() { _quarantine_active CONFIG_QUARANTINE_HASH CONFIG_QUARANTINE_TS "$1"; }
self_quarantine_set()      { _quarantine_set    SELF_QUARANTINE_DIGEST SELF_QUARANTINE_TS "$1"; }
self_quarantine_clear()    { _quarantine_clear  SELF_QUARANTINE_DIGEST SELF_QUARANTINE_TS; }
self_quarantine_active()   { _quarantine_active SELF_QUARANTINE_DIGEST SELF_QUARANTINE_TS "$1"; }

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
