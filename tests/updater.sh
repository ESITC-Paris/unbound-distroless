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

t_discover() {
  local dir="$TEST_TMPDIR/upd-discover-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    discover_target
    echo "service=$TARGET_SERVICE"
    echo "workdir=$COMPOSE_WORKDIR"
    echo "declared=$DECLARED_IMAGE_REF"
    echo "volume=$TARGET_STATE_VOLUME"
    echo "confmounts=${DECLARED_CONF_MOUNTS[*]}"
    echo "fp=$(config_fingerprint)"
    echo "running=$(running_digest)"') || fail "discover_target failed: $out"

  grep -q '^service=unbound$'                       <<<"$out" || fail "bad service: $out"
  grep -q "^workdir=$dir\$"                         <<<"$out" || fail "bad workdir: $out"
  grep -q '^declared=esitcparis/unbound-distroless:1$' <<<"$out" || fail "bad declared ref: $out"
  grep -q '^volume=.*state$'                        <<<"$out" || fail "bad state volume: $out"
  grep -q "confmounts=.*$dir/unbound.conf:/etc/unbound/unbound.conf" <<<"$out" || fail "conf mount not discovered: $out"
  grep -qE '^fp=[0-9a-f]{64}$'                      <<<"$out" || fail "bad fingerprint: $out"
  grep -qE '^running=esitcparis/unbound-distroless@sha256:[0-9a-f]{64}$' <<<"$out" || fail "bad running digest: $out"
  pass "discovery derives service, workdir, declared ref, volume, conf mounts"
}

t_config_fingerprint_handles_spaces() {
  # A compose project can live anywhere on the host, including under a path
  # containing a space. config_fingerprint must hash the declared file
  # correctly there too, rather than let sort/xargs's default whitespace
  # splitting silently feed the wrong (or no) file to sha256sum.
  local dir="$TEST_TMPDIR/upd discover space-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"

  local discover_and_fingerprint='
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    discover_target
    config_fingerprint'

  local fp1 fp2
  fp1=$(updater_exec "$dir" /bin/bash -c "$discover_and_fingerprint") \
    || fail "discovery/fingerprint failed under a space-containing path: $fp1"
  grep -qE '^[0-9a-f]{64}$' <<<"$fp1" || fail "fingerprint is not a real sha256 digest: $fp1"

  # Perturb the declared config's content; the fingerprint must move.
  echo '# comment added to change content-hash' >> "$dir/unbound.conf"
  fp2=$(updater_exec "$dir" /bin/bash -c "$discover_and_fingerprint") \
    || fail "discovery/fingerprint failed after editing config: $fp2"
  grep -qE '^[0-9a-f]{64}$' <<<"$fp2" || fail "fingerprint is not a real sha256 digest: $fp2"

  [ "$fp1" != "$fp2" ] || fail "fingerprint did not change after the config file's contents changed"
  pass "config_fingerprint hashes correctly and changes on edit under a path containing a space"
}

t_validate() {
  local dir="$TEST_TMPDIR/upd-validate-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    discover_target
    ip=$(target_probe_ip)
    wait_resolver "$ip" 90    || { echo "readiness failed"; exit 1; }
    validate_resolver "$ip"   || { echo "validation failed"; exit 1; }
    validate_resolver 192.0.2.1 && { echo "dead address must not validate"; exit 1; }
    echo OK') || fail "validation failed: $out"
  grep -q '^OK$' <<<"$out" || fail "validate did not reach OK: $out"
  pass "readiness probe and DNS criteria (UDP, TCP, AD flag); dead address rejected"
}

t0_image_sane
t0_state_unit
t_discover
t_config_fingerprint_handles_spaces
t_validate
echo "ALL UPDATER TESTS PASSED"
