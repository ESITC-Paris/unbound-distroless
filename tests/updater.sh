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
    echo "bindmounts=${DECLARED_BIND_MOUNTS[*]}"
    echo "fp=$(config_fingerprint)"
    echo "running=$(running_digest)"') || fail "discover_target failed: $out"

  grep -q '^service=unbound$'                       <<<"$out" || fail "bad service: $out"
  grep -q "^workdir=$dir\$"                         <<<"$out" || fail "bad workdir: $out"
  grep -q '^declared=esitcparis/unbound-distroless:1$' <<<"$out" || fail "bad declared ref: $out"
  grep -q '^volume=.*state$'                        <<<"$out" || fail "bad state volume: $out"
  grep -q "bindmounts=.*$dir/unbound.conf:/etc/unbound/unbound.conf" <<<"$out" || fail "bind mount not discovered: $out"
  grep -qE '^fp=[0-9a-f]{64}$'                      <<<"$out" || fail "bad fingerprint: $out"
  grep -qE '^running=esitcparis/unbound-distroless@sha256:[0-9a-f]{64}$' <<<"$out" || fail "bad running digest: $out"
  pass "discovery derives service, workdir, declared ref, volume, bind mounts"
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

t4_invalid_conf_rejected() {
  local dir="$TEST_TMPDIR/upd-t4-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local before; before=$(running_ref "$dir")
  printf 'server:\n  this-is-not-a-directive: 1\n' > "$dir/unbound.conf"
  local out rc=0
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    preflight_checkconf "$DECLARED_IMAGE_REF"' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "preflight accepted an invalid configuration"
  grep -qi 'unknown keyword\|error' <<<"$out" || fail "preflight did not surface unbound's own error: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "production container was touched by a failed preflight"
  pass "T4: invalid configuration rejected in preflight, production untouched"
}

t5_healthcheck_breaking_conf() {
  local dir="$TEST_TMPDIR/upd-t5-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  # The exact trap in this project's own unbound.conf.local: remote-control
  # over TCP/TLS, whose key and certificate files are deliberately absent
  # from the image. REPLACE the shipped unbound.conf's own remote-control
  # clause (a unix socket, for the healthcheck) rather than appending next to
  # it: unbound only enforces TLS key/cert files when the FIRST
  # control-interface in the merged config is an address, so appending here
  # would leave the unix socket first and the check would never fire —
  # that's a real, separate quirk (see preflight_checkconf's warning), not
  # this test's concern. A single, address-only remote-control clause is
  # what genuinely fails unbound-checkconf today.
  sed -i.bak '/^remote-control:$/,/^$/d' "$dir/unbound.conf"
  rm -f "$dir/unbound.conf.bak"
  cat >> "$dir/unbound.conf" <<'CONF'
remote-control:
  control-enable: yes
  control-interface: 127.0.0.1
  control-port: 8953
  server-key-file: "/etc/unbound/unbound_server.key"
  server-cert-file: "/etc/unbound/unbound_server.pem"
  control-key-file: "/etc/unbound/unbound_control.key"
  control-cert-file: "/etc/unbound/unbound_control.pem"
CONF
  local out rc=0 start elapsed
  start=$(date -u +%s)
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    preflight_checkconf "$DECLARED_IMAGE_REF"' 2>&1) || rc=$?
  elapsed=$(( $(date -u +%s) - start ))
  [ "$rc" -ne 0 ] || fail "preflight accepted a config whose control files do not exist"
  grep -q 'unbound_server.key' <<<"$out" || fail "preflight did not name the missing file: $out"
  [ "$elapsed" -lt 30 ] || fail "preflight took ${elapsed}s — it timed out instead of reporting precisely"
  pass "T5: control-file trap reported precisely by checkconf, not as a timeout"
}

t_canary_lifecycle() {
  local dir="$TEST_TMPDIR/upd-canary-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    trap canary_down EXIT
    canary_up "$DECLARED_IMAGE_REF"
    wait_resolver "$CANARY_IP" 90
    validate_resolver "$CANARY_IP"
    echo OK') || fail "canary lifecycle failed: $out"
  grep -q '^OK$' <<<"$out" || fail "canary did not validate: $out"
  # Nothing must survive the run.
  docker ps -a --format '{{.Names}}' | grep -q 'unbound-canary' && fail "canary container leaked"
  docker volume ls --format '{{.Name}}'  | grep -q 'unbound-canary' && fail "canary volume leaked"
  docker network ls --format '{{.Name}}' | grep -q 'unbound-canary' && fail "canary network leaked"
  pass "canary starts on cloned state, validates, and leaves nothing behind"
}

t1_image_update_actually_lands() {
  local dir="$TEST_TMPDIR/upd-t1-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$OLD_REF"
  local before; before=$(running_ref "$dir")

  # A new release appears: the declared tag now resolves to a newer digest.
  fixture_set_image "$dir" "$MOVING_REF"
  updater_run "$dir" || fail "cycle failed"

  local after declared
  after=$(running_ref "$dir")
  docker pull -q "$MOVING_REF" >/dev/null
  declared=$(docker image inspect "$MOVING_REF" --format '{{.Id}}')

  [ "$after" != "$before" ] || fail "T1: the container is still on the old image — the swap was a no-op"
  [ "$after" = "$declared" ] || fail "T1: running image ($after) is not the declared image ($declared)"
  pass "T1: after a cycle the container really runs the declared image"
}

t2_noop_second_cycle() {
  local dir="$TEST_TMPDIR/upd-t2-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "first cycle failed"
  local cid_before cid_after
  cid_before=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  updater_run "$dir" >/dev/null || fail "second cycle failed"
  cid_after=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  [ "$cid_before" = "$cid_after" ] || fail "T2: an unchanged cycle recreated the container"
  pass "T2: an unchanged cycle recreates nothing"
}

t3_config_change_triggers() {
  local dir="$TEST_TMPDIR/upd-t3-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local cid_before; cid_before=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)

  # A harmless, valid configuration edit.
  printf '\nserver:\n  cache-min-ttl: 120\n' >> "$dir/unbound.conf"
  updater_run "$dir" || fail "config-change cycle failed"

  local cid_after; cid_after=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  [ "$cid_before" != "$cid_after" ] || fail "T3: editing the configuration did not redeploy"
  pass "T3: a configuration change is canaried and deployed"
}

t0_image_sane
t0_state_unit
t_discover
t_config_fingerprint_handles_spaces
t_validate
t4_invalid_conf_rejected
t5_healthcheck_breaking_conf
t_canary_lifecycle
t1_image_update_actually_lands
t2_noop_second_cycle
t3_config_change_triggers
echo "ALL UPDATER TESTS PASSED"
