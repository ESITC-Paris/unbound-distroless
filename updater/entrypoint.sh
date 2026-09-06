#!/usr/bin/env bash
# Sidecar entrypoint. Task 1 ships only the base image plus the logging and
# state libraries — the discovery/canary/orchestration loop lands in a later
# task and will replace this placeholder body.
set -euo pipefail

. /usr/local/lib/unbound-autoupdate/log.sh

log_info "unbound-autoupdate skeleton image started (no orchestration logic yet)"
exec sleep infinity
