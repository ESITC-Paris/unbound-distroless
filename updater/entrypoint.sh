#!/usr/bin/env bash
# Mode dispatch and scheduling loop.
#   loop  (default)     — a cycle every INTERVAL, with SPLAY jitter
#   once                — exactly one cycle, then exit with its status
#   check               — one cycle that validates but never swaps
#   metrics             — serve /metrics for Prometheus; never runs a cycle
#   idle                — keep the container up without running anything,
#                         for `docker compose exec` maintenance and tests
#   self-update-apply   — internal: run by the ephemeral self-update helper
set -euo pipefail

LIB=/usr/local/lib/unbound-autoupdate
# shellcheck source=updater/lib/log.sh
. "$LIB/log.sh"
# shellcheck source=updater/lib/state.sh
. "$LIB/state.sh"

MODE="${1:-${RUN_MODE:-loop}}"
INTERVAL="${INTERVAL:-1h}"
SPLAY="${SPLAY:-10%}"
VERSION=$(cat "$LIB/VERSION" 2>/dev/null || echo dev)

# _delay — INTERVAL plus a random jitter of up to SPLAY, so a fleet of
# resolvers never all update in the same minute. SPLAY is either a
# percentage of INTERVAL ("10%") or an absolute duration ("5m").
_delay() {
  local base max
  base=$(to_seconds "$INTERVAL")
  case "$SPLAY" in
    *%) local pct="${SPLAY%\%}"
        case "$pct" in ''|*[!0-9]*) log_die "invalid SPLAY: $SPLAY";; esac
        max=$(( base * pct / 100 )) ;;
    *)  max=$(to_seconds "$SPLAY") ;;
  esac
  if [ "$max" -gt 0 ]; then
    printf '%s\n' $(( base + (RANDOM % (max + 1)) ))
  else
    printf '%s\n' "$base"
  fi
}

case "$MODE" in
  once)
    exec /usr/local/bin/unbound-autoupdate
    ;;
  check)
    CHECK_ONLY=1 exec /usr/local/bin/unbound-autoupdate
    ;;
  metrics)
    # shellcheck source=updater/lib/metrics.sh
    . "$LIB/metrics.sh"
    exec_metrics_server
    ;;
  idle)
    log_info "unbound-autoupdate $VERSION idle: no cycles will run"
    exec sleep infinity
    ;;
  self-update-apply)
    shift
    # shellcheck source=updater/lib/discover.sh
    . "$LIB/discover.sh"
    # shellcheck source=updater/lib/metrics.sh
    . "$LIB/metrics.sh"
    # shellcheck source=updater/lib/selfupdate.sh
    . "$LIB/selfupdate.sh"
    self_update_apply "$@"
    ;;
  loop)
    # Validate the schedule once, up front: a typo must stop the container
    # now, not after the first cycle has run.
    _delay >/dev/null
    log_info "unbound-autoupdate $VERSION starting: interval=$INTERVAL splay=$SPLAY"
    while true; do
      # A failing cycle must not kill the loop: it has already notified, and
      # the next tick retries. Only a human decision stops the sidecar.
      /usr/local/bin/unbound-autoupdate || log_warn "cycle exited $? — continuing"
      d=$(_delay)
      log_info "next cycle in ${d}s"
      sleep "$d" &
      wait $!   # `wait` on a background sleep so tini's SIGTERM lands promptly
    done
    ;;
  *)
    log_die "unknown mode '$MODE' (expected loop, once, check, metrics or idle)"
    ;;
esac
