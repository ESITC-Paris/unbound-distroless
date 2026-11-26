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
    COLLECT=$(to_seconds "${METRICS_COLLECT_INTERVAL:-0}")
    log_info "unbound-autoupdate $VERSION starting: interval=$INTERVAL splay=$SPLAY"
    # The collector for a metrics service that runs without the Docker socket
    # (lib/metrics.sh, metrics_collect_once). In this container because this
    # one has the socket whatever happens; off unless asked for.
    COLLECTOR_PID=""
    if [ "$COLLECT" -gt 0 ]; then
      # shellcheck source=updater/lib/discover.sh
      . "$LIB/discover.sh"
      # shellcheck source=updater/lib/metrics.sh
      . "$LIB/metrics.sh"
      state_init
      log_info "metrics collector: resolver statistics every ${COLLECT}s, for a metrics service without the Docker socket"
      metrics_collector_loop "$COLLECT" & COLLECTOR_PID=$!
    fi
    # SIGTERM (docker stop) is forwarded to a running cycle, which ends at a
    # consistent point — at once outside a swap, after it inside one — and
    # the loop then exits. Without this the cycle never saw the signal and
    # was simply killed at the end of the grace period, mid-swap or not.
    CYCLE_PID=""
    _forward_term() {
      [ -z "$COLLECTOR_PID" ] || kill "$COLLECTOR_PID" 2>/dev/null || true
      if [ -n "$CYCLE_PID" ]; then kill -TERM "$CYCLE_PID" 2>/dev/null || true; wait "$CYCLE_PID" 2>/dev/null || true; fi
      exit 143
    }
    trap _forward_term TERM INT
    while true; do
      # A failing cycle must not kill the loop: it has already notified, and
      # the next tick retries. Only a human decision stops the sidecar.
      /usr/local/bin/unbound-autoupdate & CYCLE_PID=$!
      wait "$CYCLE_PID" || log_warn "cycle exited $? — continuing"
      CYCLE_PID=""
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
