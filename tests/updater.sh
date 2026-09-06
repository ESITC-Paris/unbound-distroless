#!/usr/bin/env bash
# Integration suite for the unbound-autoupdate sidecar.
# Usage: tests/updater.sh [image-tag]   (default: unbound-autoupdate:test)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/updater/lib.sh
. "$HERE/updater/lib.sh"

UPDATER_IMAGE="${1:-unbound-autoupdate:test}"

t0_image_sane() {
  docker image inspect "$UPDATER_IMAGE" >/dev/null 2>&1 || fail "image $UPDATER_IMAGE not built"
  for b in docker cosign dig bash flock; do
    docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c "command -v $b" >/dev/null \
      || fail "missing binary in image: $b"
  done
  docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c 'docker compose version' >/dev/null \
    || fail "docker compose plugin missing"
  docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c 'cosign version' >/dev/null \
    || fail "cosign not runnable"
  pass "image contains docker+compose+cosign+dig+bash+flock"
}

t0_state_unit() {
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st RETRY_AFTER=1h
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    state_init
    [ -z "$(state_get LAST_IMAGE_DIGEST)" ] || { echo "expected empty"; exit 1; }
    state_set LAST_IMAGE_DIGEST "repo@sha256:aaa"
    [ "$(state_get LAST_IMAGE_DIGEST)" = "repo@sha256:aaa" ] || { echo "roundtrip failed"; exit 1; }
    state_set LAST_IMAGE_DIGEST "repo@sha256:bbb"
    [ "$(state_get LAST_IMAGE_DIGEST)" = "repo@sha256:bbb" ] || { echo "overwrite failed"; exit 1; }
    quarantine_active "repo@sha256:ccc" && { echo "should not be quarantined"; exit 1; }
    quarantine_set "repo@sha256:ccc"
    quarantine_active "repo@sha256:ccc" || { echo "should be quarantined"; exit 1; }
    quarantine_active "repo@sha256:ddd" && { echo "other digest must not be quarantined"; exit 1; }
    quarantine_clear
    quarantine_active "repo@sha256:ccc" && { echo "clear failed"; exit 1; }
    [ "$(to_seconds 45s)" = 45 ] && [ "$(to_seconds 30m)" = 1800 ] \
      && [ "$(to_seconds 1h)" = 3600 ] && [ "$(to_seconds 2d)" = 172800 ] \
      && [ "$(to_seconds 90)" = 90 ] || { echo "to_seconds failed"; exit 1; }
    echo OK') || fail "state unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "state unit did not print OK: $out"
  pass "state, quarantine and to_seconds behave"
}

t0_image_sane
t0_state_unit
echo "ALL UPDATER TESTS PASSED"
