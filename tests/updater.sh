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
    # config_quarantine_* mirrors quarantine_* exactly, keyed on a
    # configuration fingerprint instead of an image digest (I4).
    config_quarantine_active "confhash1" && { echo "should not be config-quarantined"; exit 1; }
    config_quarantine_set "confhash1"
    config_quarantine_active "confhash1" || { echo "should be config-quarantined"; exit 1; }
    config_quarantine_active "confhash2" && { echo "other fingerprint must not be config-quarantined"; exit 1; }
    config_quarantine_clear
    config_quarantine_active "confhash1" && { echo "config clear failed"; exit 1; }
    [ "$(to_seconds 45s)" = 45 ] && [ "$(to_seconds 30m)" = 1800 ] \
      && [ "$(to_seconds 1h)" = 3600 ] && [ "$(to_seconds 2d)" = 172800 ] \
      && [ "$(to_seconds 90)" = 90 ] || { echo "to_seconds failed"; exit 1; }
    echo OK') || fail "state unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "state unit did not print OK: $out"
  pass "state, quarantine, config-quarantine and to_seconds behave"
}

t0_logfmt_unit() {
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    # The point of the change: an ordinary operator message must arrive
    # completely untouched. It used to come out %q-escaped, so every space in
    # it became a backslash and plain-English greps could not match it.
    plain="cosign verification FAILED for repo@sha256:abc — refusing to deploy"
    [ "$(_logfmt_escape "$plain")" = "$plain" ] || { echo "a plain message was altered"; exit 1; }
    [ "$(_logfmt_escape "a\\b")"  = "a\\\\b" ] || { echo "backslash not doubled"; exit 1; }
    [ "$(_logfmt_escape "a\"b")"  = "a\\\"b"  ] || { echo "double quote not escaped"; exit 1; }
    [ "$(_logfmt_escape "$(printf "a\nb")")" = "a\\nb" ] || { echo "embedded newline not collapsed"; exit 1; }
    # Carriage return and tab pass through by design (see log.sh): neither can
    # split a line, so escaping them would only hurt readability.
    [ "$(_logfmt_escape "$(printf "a\tb")")" = "$(printf "a\tb")" ] || { echo "tab should pass through"; exit 1; }
    # The property all of that exists to protect: one call, one line.
    line=$(log_info "$(printf "rolling back\nto the old image")")
    [ "$(printf %s "$line" | wc -l)" = 0 ] || { echo "a log line was split in two"; exit 1; }
    echo OK') || fail "logfmt unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "logfmt unit did not print OK: $out"
  pass "_logfmt_escape escapes backslash, quote and newline, and leaves plain text alone"
}

t0_compose_file_args_unit() {
  # A unit test rather than a two-compose-file fixture: these are pure string
  # shapes, so asserting them in a bare container is fast, deterministic and
  # needs neither Docker Hub nor Sigstore — where the equivalent integration
  # coverage would need both, and would still only reach one shape per run.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    mkdir -p /proj /tmp/st
    : > /proj/docker-compose.yml
    : > /proj/override.yml
    : > "$ROLLBACK_FILE"
    COMPOSE_WORKDIR=/proj

    # One absolute path: the everyday shape, and the one that silently
    # produced an EMPTY list for as long as the label was fed to read without
    # a trailing newline.
    _compose_file_args "/proj/docker-compose.yml"
    [ "${COMPOSE_FILE_ARGS[*]}" = "-f /proj/docker-compose.yml" ] \
      || { echo "single file: [${COMPOSE_FILE_ARGS[*]}]"; exit 1; }

    # Two files, order preserved — Compose applies each -f on top of the last,
    # so reordering them would silently change what gets deployed.
    _compose_file_args "/proj/docker-compose.yml,/proj/override.yml"
    [ "${COMPOSE_FILE_ARGS[*]}" = "-f /proj/docker-compose.yml -f /proj/override.yml" ] \
      || { echo "two files: [${COMPOSE_FILE_ARGS[*]}]"; exit 1; }

    # A trailing separator must not turn into an empty -f argument.
    _compose_file_args "/proj/docker-compose.yml,"
    [ "${COMPOSE_FILE_ARGS[*]}" = "-f /proj/docker-compose.yml" ] \
      || { echo "trailing separator: [${COMPOSE_FILE_ARGS[*]}]"; exit 1; }

    # Compose records relative paths when it was invoked with one.
    _compose_file_args "docker-compose.yml,override.yml"
    [ "${COMPOSE_FILE_ARGS[*]}" = "-f /proj/docker-compose.yml -f /proj/override.yml" ] \
      || { echo "relative paths: [${COMPOSE_FILE_ARGS[*]}]"; exit 1; }

    # The rollback override is a transient artefact of one cycle and must
    # never re-enter the project definition, however it reaches this label.
    _compose_file_args "/proj/docker-compose.yml,$ROLLBACK_FILE"
    [ "${COMPOSE_FILE_ARGS[*]}" = "-f /proj/docker-compose.yml" ] \
      || { echo "rollback override not filtered: [${COMPOSE_FILE_ARGS[*]}]"; exit 1; }

    # And that filter must fail loudly rather than degrade to matching
    # nothing, which would let the override back in with no error at all.
    if ( unset ROLLBACK_FILE; _compose_file_args "/proj/docker-compose.yml" ) 2>/dev/null; then
      echo "an unset ROLLBACK_FILE was tolerated"; exit 1
    fi
    echo OK') || fail "compose file args unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "compose file args unit did not print OK: $out"
  pass "compose file list: single, multiple, trailing separator, relative paths, rollback override filtered"
}

t0_notify_host_unit() {
  # Notifications name the machine they come from. Inside a container,
  # `hostname` is the container's short id, which tells an operator with a
  # fleet of resolvers nothing. NOTIFY_HOST wins when set; otherwise the
  # Docker daemon's own host name; only then the container hostname.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    [ "$(NOTIFY_HOST=resolver-1.example _notify_host)" = "resolver-1.example" ] \
      || { echo "NOTIFY_HOST override ignored"; exit 1; }
    # No docker socket in this bare container: the fallback is the hostname.
    [ "$(_notify_host)" = "$(hostname)" ] || { echo "fallback is not the hostname"; exit 1; }
    echo OK') || fail "notify host unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "notify host unit did not print OK: $out"
  pass "_notify_host honours NOTIFY_HOST and falls back to the container hostname"
}

t0_config_fingerprint_directory_unit() {
  # A declared bind mount may be a DIRECTORY (the shipped unbound.conf's DoT
  # example mounts a whole tls/ directory). The fingerprint must cover the
  # files inside it — a rotated certificate is exactly the kind of change
  # that must trigger a canary — and must never silently degrade to hashing
  # nothing: `cat` on a directory fails, and a `printf "$(pipeline)"` wrapper
  # used to swallow that failure and return the hash of an empty input.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    mkdir -p /tmp/st /tls; echo conf > /u.conf; echo cert1 > /tls/server.pem
    empty=$(printf "" | sha256sum | cut -d" " -f1)

    DECLARED_BIND_MOUNTS=(-v /tls:/etc/unbound/tls:ro)
    h_dir=$(config_fingerprint 2>/dev/null) || { echo "directory-only mount failed"; exit 1; }
    [ "$h_dir" != "$empty" ] || { echo "a directory mount hashed as empty input"; exit 1; }

    DECLARED_BIND_MOUNTS=(-v /u.conf:/etc/unbound/unbound.conf:ro -v /tls:/etc/unbound/tls:ro)
    h1=$(config_fingerprint 2>/dev/null)
    echo cert2 > /tls/server.pem
    h2=$(config_fingerprint 2>/dev/null)
    [ "$h1" != "$h2" ] || { echo "a file changed inside a mounted directory but the fingerprint did not"; exit 1; }

    # Renaming a file inside the directory is a change too (a cert that
    # unbound.conf no longer finds under its old name is a broken config).
    mv /tls/server.pem /tls/renamed.pem
    h3=$(config_fingerprint 2>/dev/null)
    [ "$h2" != "$h3" ] || { echo "a rename inside a mounted directory was invisible"; exit 1; }

    # An unreadable path must fail loudly, never hash partially.
    DECLARED_BIND_MOUNTS=(-v /u.conf:/etc/unbound/unbound.conf:ro -v /does/not/exist:/etc/unbound/x:ro)
    if config_fingerprint >/dev/null 2>&1; then echo "a missing path was silently hashed"; exit 1; fi
    echo OK') || fail "config_fingerprint directory unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "config_fingerprint directory unit did not print OK: $out"
  pass "config_fingerprint covers files inside directory mounts, sees renames, fails loudly on a missing path"
}

t0_stats_to_prometheus_unit() {
  # A canned stats_noreset excerpt (the shapes unbound 1.26 actually prints)
  # must come out as valid exposition text: grouped families, HELP and TYPE
  # on every one, labels where the key encodes a dimension, and a real
  # cumulative histogram built from unbound's non-cumulative buckets.
  local out="$TEST_TMPDIR/upd-stats-$$.prom"
  docker run --rm -i --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    stats_to_prometheus' > "$out" <<'STATS'
thread0.num.queries=7
thread0.num.cachehits=3
thread0.requestlist.avg=0.5
thread0.query.queue_time_us.max=0
thread1.num.queries=5
thread1.num.cachehits=2
thread1.requestlist.avg=0
thread1.query.queue_time_us.max=1500
total.num.queries=12
total.num.cachehits=5
total.num.recursivereplies=4
total.requestlist.avg=0.25
total.query.queue_time_us.max=1500
total.recursion.time.avg=0.125000
total.recursion.time.median=0.05
total.tcpusage=0
time.now=1789568511.123456
time.up=100.500000
time.elapsed=100.500000
mem.cache.rrset=4096
mem.cache.message=2048
mem.mod.validator=512
histogram.000000.000000.to.000000.000001=0
histogram.000000.000001.to.000000.000002=1
histogram.000000.000002.to.000000.000004=2
histogram.000000.000004.to.000000.000008=1
num.query.type.A=10
num.query.type.AAAA=2
num.query.class.IN=12
num.query.opcode.QUERY=12
num.query.tcp=1
num.query.flags.RD=12
num.query.edns.present=12
num.answer.rcode.NOERROR=11
num.answer.rcode.NXDOMAIN=1
num.query.aggressive.NXDOMAIN=1
num.answer.secure=9
num.answer.bogus=0
num.rrset.bogus=0
unwanted.queries=0
unwanted.replies=0
msg.cache.count=8
rrset.cache.count=20
infra.cache.count=3
key.cache.count=2
STATS
  promtool_check "$out" || fail "stats_to_prometheus output rejected by promtool: $(cat "$out")"
  local expect
  for expect in \
    '^unbound_queries_total 12$' \
    '^unbound_thread_queries_total{thread="1"} 5$' \
    '^unbound_thread_requestlist_avg{thread="0"} 0.5$' \
    '^unbound_query_types_total{type="AAAA"} 2$' \
    '^unbound_answer_rcodes_total{rcode="NXDOMAIN"} 1$' \
    '^unbound_query_aggressive_total{rcode="NXDOMAIN"} 1$' \
    '^unbound_answers_secure_total 9$' \
    '^unbound_recursion_time_seconds{stat="median"} 0.05$' \
    '^unbound_query_queue_time_seconds\{stat="max"\} 0.001500$' \
    '^unbound_thread_query_queue_time_seconds\{thread="1",stat="max"\} 0.001500$' \
    '^unbound_time_up_seconds 100.5' \
    '^unbound_mem_cache_rrset_bytes 4096$' \
    '^unbound_cache_entries{cache="rrset"} 20$' \
    '^unbound_stat{name="num.query.tcp"} 1$' \
    '^unbound_response_time_seconds_bucket{le="2e-06"} 1$' \
    '^unbound_response_time_seconds_bucket{le="8e-06"} 4$' \
    '^unbound_response_time_seconds_bucket\{le="\+Inf"\} 4$' \
    '^unbound_response_time_seconds_count 4$' \
    '^unbound_response_time_seconds_sum 0.5$' \
    '^# TYPE unbound_queries_total counter$' \
    '^# TYPE unbound_requestlist_avg gauge$' \
    '^# TYPE unbound_response_time_seconds histogram$'; do
    grep -qE "$expect" "$out" || fail "stats_to_prometheus: missing '$expect' in: $(cat "$out")"
  done
  # Families must be grouped: HELP for a name appears exactly once.
  [ "$(grep -c '^# HELP unbound_thread_queries_total ' "$out")" = 1 ] || fail "thread family emitted more than once"

  # unbound-control does not only print key=value: a failed connection prints
  # free-form text, and the socket can hand back a blank line. A record with
  # no value would be emitted as a value-less sample, which makes a Prometheus
  # parser reject the WHOLE document — losing every other metric exactly when
  # something is already wrong. A key can also carry characters that are not
  # legal unescaped inside a label value (unbound prints unknown RR types as
  # TYPE<n>, and a quote there must not break out of the label).
  local bad="$TEST_TMPDIR/upd-stats-bad-$$.prom"
  docker run --rm -i --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    stats_to_prometheus' > "$bad" <<'BADSTATS'
error: connect failed

total.num.queries=12
num.query.type.TYPE"65=1
weird.back\slash.and"quote=3
BADSTATS
  promtool_check "$bad" || fail "malformed stats lines poisoned the document: $(cat "$bad")"
  if grep -q 'name="error' "$bad"; then fail "a free-form error line was emitted as a sample: $(cat "$bad")"; fi
  if grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*(\{[^}]*\})? *$' "$bad"; then fail "a value-less sample was emitted: $(cat "$bad")"; fi
  grep -qE '^unbound_queries_total 12$' "$bad" || fail "malformed lines swallowed the valid ones: $(cat "$bad")"
  rm -f "$bad"
  rm -f "$out"
  pass "stats_to_prometheus: valid exposition text, labels, grouped families, cumulative histogram"
}

t0_cycle_metrics_unit() {
  local out="$TEST_TMPDIR/upd-cycle-$$.prom" res
  res=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st RETRY_AFTER=1h
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    state_init
    state_inc CYCLES_TEST; state_inc CYCLES_TEST
    [ "$(state_get CYCLES_TEST)" = 2 ] || { echo "state_inc failed: $(state_get CYCLES_TEST)"; exit 1; }
    self_quarantine_active "d1" && { echo "self quarantine should be inactive"; exit 1; }
    self_quarantine_set "d1"
    self_quarantine_active "d1" || { echo "self quarantine should be active"; exit 1; }
    _quarantine_window_open SELF_QUARANTINE_TS || { echo "window should be open"; exit 1; }
    _quarantine_window_open QUARANTINE_TS && { echo "image window should be closed"; exit 1; }
    state_set LAST_IMAGE_DIGEST "esitcparis/unbound-distroless@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    record_cycle rollback 42
    record_cycle up_to_date 3
    echo "===="
    cat /tmp/st/metrics.prom') || fail "cycle metrics unit failed: $res"
  printf '%s\n' "${res#*====$'\n'}" > "$out"
  promtool_check "$out" || fail "metrics.prom rejected by promtool: $(cat "$out")"
  local expect
  for expect in \
    '^unbound_autoupdate_last_cycle_status{status="up_to_date"} 1$' \
    '^unbound_autoupdate_last_cycle_status{status="rollback"} 0$' \
    '^unbound_autoupdate_last_cycle_duration_seconds 3$' \
    '^unbound_autoupdate_cycles_total{status="rollback"} 1$' \
    '^unbound_autoupdate_cycles_total{status="up_to_date"} 1$' \
    '^unbound_autoupdate_cycles_total{status="critical"} 0$' \
    '^unbound_autoupdate_quarantine_active{axis="self"} 1$' \
    '^unbound_autoupdate_quarantine_active{axis="image"} 0$' \
    '^unbound_autoupdate_target_image_info{digest="esitcparis/unbound-distroless@sha256:0000' \
    '^unbound_autoupdate_info{version="' \
    '^unbound_autoupdate_self_update_last_timestamp_seconds 0$' \
    '^unbound_autoupdate_last_cycle_timestamp_seconds [0-9]{10}$'; do
    grep -qE "$expect" "$out" || fail "cycle metrics: missing '$expect' in: $(cat "$out")"
  done
  rm -f "$out"
  pass "record_cycle persists status and counters and writes a valid metrics.prom"
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
    echo "running=$(running_digest)"
    echo "composefiles=${COMPOSE_FILE_ARGS[*]}"
    echo "selfimageid=$SELF_IMAGE_ID"
    echo "repo=$(_image_repo "127.0.0.1:5000/unbound-x:1") $(_image_repo "127.0.0.1:5000/unbound-x@sha256:abc") $(_image_repo "esitcparis/unbound-distroless:1.26.0-r3")"
    echo "notifyhost=$(_notify_host)"') || fail "discover_target failed: $out"

  # With the socket mounted, notifications carry the DAEMON host's name —
  # the machine the operator knows — not the sidecar's container id.
  grep -q "^notifyhost=$(docker info --format '{{.Name}}')\$" <<<"$out" \
    || fail "notify host is not the docker daemon's host name: $out"

  grep -qE '^selfimageid=sha256:[0-9a-f]{64}$' <<<"$out" || fail "SELF_IMAGE_ID not derived: $out"
  grep -q '^repo=127.0.0.1:5000/unbound-x 127.0.0.1:5000/unbound-x esitcparis/unbound-distroless$' <<<"$out" \
    || fail "_image_repo mishandles a registry port, a digest or a tag: $out"

  grep -q '^service=unbound$'                       <<<"$out" || fail "bad service: $out"
  grep -q "^workdir=$dir\$"                         <<<"$out" || fail "bad workdir: $out"
  grep -q '^declared=esitcparis/unbound-distroless:1$' <<<"$out" || fail "bad declared ref: $out"
  grep -q '^volume=.*state$'                        <<<"$out" || fail "bad state volume: $out"
  grep -q "bindmounts=.*$dir/unbound.conf:/etc/unbound/unbound.conf" <<<"$out" || fail "bind mount not discovered: $out"
  grep -qE '^fp=[0-9a-f]{64}$'                      <<<"$out" || fail "bad fingerprint: $out"
  grep -qE '^running=esitcparis/unbound-distroless@sha256:[0-9a-f]{64}$' <<<"$out" || fail "bad running digest: $out"
  # The one variable nothing used to assert — which is exactly why it could
  # sit permanently empty (Bug A) while every other check here still passed.
  # Everything downstream papers over an empty list, because Compose then
  # discovers the file from --project-directory by itself; only the rollback,
  # which adds a second -f, ever noticed.
  grep -q "^composefiles=-f $dir/docker-compose.yml\$" <<<"$out" \
    || fail "COMPOSE_FILE_ARGS was not derived from the compose label: $out"
  pass "discovery derives service, workdir, declared ref, volume, bind mounts, compose file args; a sibling on the sidecar's own image is never a candidate"
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

t_validate_dnssec_optional() {
  # A resolver deliberately run without the validator (module-config
  # "iterator", e.g. a forwarder to an internal, unsigned upstream) never
  # sets the AD flag. Requiring it by default is right — but with no way to
  # opt out, such a deployment would be refused on EVERY cycle forever, the
  # permanent-update-block class the sidecar exists to remove.
  local dir="$TEST_TMPDIR/upd-nodnssec-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  sed -i.bak 's/^  module-config: "validator iterator"$/  module-config: "iterator"/' "$dir/unbound.conf"
  rm -f "$dir/unbound.conf.bak"
  grep -q '^  module-config: "iterator"$' "$dir/unbound.conf" || fail "test setup: could not disable the validator"
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" up -d --force-recreate unbound ) >/dev/null 2>&1

  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    discover_target
    ip=$(target_probe_ip)
    wait_resolver "$ip" 90 || { echo "readiness failed"; exit 1; }
    if validate_resolver "$ip" 2>/dev/null; then echo "a non-validating resolver passed with DNSSEC required"; exit 1; fi
    REQUIRE_DNSSEC=0 validate_resolver "$ip" || { echo "REQUIRE_DNSSEC=0 still demanded the AD flag"; exit 1; }
    echo OK') || fail "dnssec-optional validation failed: $out"
  grep -q '^OK$' <<<"$out" || fail "dnssec-optional validation did not reach OK: $out"
  pass "DNSSEC AD flag is required by default and waived with REQUIRE_DNSSEC=0"
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

t_canary_replicates_declared_runtime() {
  # The canary must run under the same runtime settings Compose will give
  # production, not just the same image, state and bind mounts. A canary
  # with a writable rootfs, no tmpfs, no ulimits and no environment can pass
  # while production, declared read-only with a tmpfs, fails — or the other
  # way round. Every setting below is read back from the canary container
  # itself, and the canary must still validate under them.
  local dir="$TEST_TMPDIR/upd-fidelity-$$"
  trap 'fixture_destroy "$dir"' RETURN
  FIXTURE_UNBOUND_EXTRA='    read_only: true
    tmpfs: ["/run/unbound:uid=65532,gid=65532"]
    environment:
      CANARY_FIDELITY_PROBE: "42"
    ulimits:
      nofile: {soft: 4096, hard: 8192}
    sysctls:
      net.ipv4.ip_unprivileged_port_start: 1024' \
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
    j=$(docker inspect "$CANARY_NAME")
    jq -e ".[0].HostConfig.ReadonlyRootfs == true" <<<"$j" >/dev/null || { echo "canary rootfs is not read-only"; exit 1; }
    jq -e ".[0].HostConfig.Tmpfs[\"/run/unbound\"] | test(\"uid=65532\")" <<<"$j" >/dev/null || { echo "canary lacks the declared tmpfs"; exit 1; }
    jq -e ".[0].Config.Env | index(\"CANARY_FIDELITY_PROBE=42\")" <<<"$j" >/dev/null || { echo "canary lacks the declared environment"; exit 1; }
    jq -e ".[0].HostConfig.Ulimits[] | select(.Name==\"nofile\" and .Soft==4096 and .Hard==8192)" <<<"$j" >/dev/null || { echo "canary lacks the declared ulimit"; exit 1; }
    jq -e ".[0].HostConfig.Sysctls[\"net.ipv4.ip_unprivileged_port_start\"] == \"1024\"" <<<"$j" >/dev/null || { echo "canary lacks the declared sysctl"; exit 1; }
    wait_resolver "$CANARY_IP" 90
    validate_resolver "$CANARY_IP"
    echo OK') || fail "canary fidelity failed: $out"
  grep -q '^OK$' <<<"$out" || fail "canary fidelity did not reach OK: $out"
  pass "canary replicates read_only, tmpfs, environment, ulimits and sysctls from the declared service"
}

t_canary_refused_in_host_network_mode() {
  # A sidecar declared with network_mode: host (which target_probe_ip
  # requires whenever the resolver itself runs in host mode) cannot be
  # connected to the canary's isolated bridge network: the daemon refuses
  # `docker network connect` for host-networked containers. The canary is
  # therefore unsupported there — and that must be said up front, in one
  # precise message, before any canary object is created, rather than
  # discovered as a generic "cannot join the canary network" after a network,
  # a volume, a cloned state and a container have already been made.
  local dir="$TEST_TMPDIR/upd-hostmode-$$"
  trap 'fixture_destroy "$dir"' RETURN
  FIXTURE_UPDATER_EXTRA='    network_mode: host' \
    fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out rc=0 start elapsed
  start=$(date -u +%s)
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    if canary_up "$DECLARED_IMAGE_REF"; then canary_down; echo "canary started under network_mode: host"; exit 1; fi
    echo REFUSED' 2>&1) || rc=$?
  elapsed=$(( $(date -u +%s) - start ))
  grep -q '^REFUSED$' <<<"$out" || fail "host-mode canary: canary_up did not fail: $out"
  grep -q 'network_mode: host' <<<"$out" || fail "host-mode canary: the refusal does not name network_mode: host as the cause: $out"
  [ "$elapsed" -lt 20 ] || fail "host-mode canary: refusal took ${elapsed}s — it built the canary before failing"
  docker ps -a --format '{{.Names}}' | grep -q 'unbound-canary' && fail "host-mode canary: a canary container was created before the refusal"
  docker network ls --format '{{.Name}}' | grep -q 'unbound-canary' && fail "host-mode canary: a canary network was created before the refusal"
  pass "host-networked sidecar: canary refused up front with a precise message, nothing created"
}

t_verify_key_accepts_signed() {
  # Key-based verification, for private mirrors that re-sign: an image
  # signed with the configured public key passes, the same bits unsigned do
  # not, and the refusal carries cosign's own reason — not a connection
  # error, which is what an unreachable registry would produce.
  local dir="$TEST_TMPDIR/upd-keyed-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local signed unsigned
  signed=$(registry_publish "FROM $MOVING_REF
LABEL test.keyed=\"1\"" "unbound-keyed:1")
  unsigned=$(registry_publish "FROM $MOVING_REF
LABEL test.keyed=\"0\"" "unbound-unkeyed:1")
  registry_sign "$dir" "$signed"

  local out
  out=$(updater_exec "$dir" /bin/bash -c "
    set -uo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/verify.sh
    export COSIGN_PUBLIC_KEY=$TEST_PUBKEY COSIGN_IGNORE_TLOG=1
    verify_image '$signed' 2>/tmp/err || { echo 'signed image refused:'; cat /tmp/err; exit 1; }
    if verify_image '$unsigned' 2>/tmp/err; then echo 'unsigned image accepted'; exit 1; fi
    grep -qiE 'no signatures found|no matching signatures' /tmp/err || { echo 'refusal is not about signatures:'; cat /tmp/err; exit 1; }
    # An unreadable key file must be a clear refusal, never a fall-through to keyless.
    if COSIGN_PUBLIC_KEY=/does/not/exist verify_image '$signed' 2>/tmp/err; then echo 'missing key file was ignored'; exit 1; fi
    grep -q 'not readable' /tmp/err || { echo 'missing key not reported:'; cat /tmp/err; exit 1; }
    echo OK") || fail "key verification: $out"
  grep -q '^OK$' <<<"$out" || fail "key verification did not reach OK: $out"
  pass "verify_image: key mode accepts a key-signed image, refuses an unsigned one with cosign's reason, refuses a missing key"
}

t6_unsigned_image_refused() {
  local dir="$TEST_TMPDIR/upd-t6-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  # Same bits as a real release, but pushed to a registry we control and
  # therefore never signed by the release pipeline. It must not reach production.
  local fake
  fake=$(registry_publish "FROM $MOVING_REF" "unbound-unsigned:1")

  fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image_raw "$dir" 'unbound-distroless' "$fake"
  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T6: an unsigned image was accepted"
  grep -qi 'cosign verification FAILED' <<<"$out" \
    || fail "T6: the run failed, but not at the signature gate — the test proves nothing: $out"
  # With the registry reachable from inside the sidecar, the refusal must be
  # cosign's verdict on the image, not a network error dressed up as one.
  grep -qiE 'no signatures found|no matching signatures' <<<"$out" \
    || fail "T6: cosign did not report a missing signature — was the registry reachable from the sidecar? $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "T6: production changed despite a failed signature check"
  pass "T6: unsigned image refused at the cosign gate, production untouched"
}

t8_major_bump_refused() {
  local dir="$TEST_TMPDIR/upd-t8-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  # Same bits, relabelled as a new major. The guard reads the OCI version
  # label rather than the tag, because a user tracking :latest has no major
  # version anywhere in their compose file.
  local fakemajor
  fakemajor=$(registry_publish \
    "FROM $MOVING_REF
LABEL org.opencontainers.image.version=\"2.0.0\"" "unbound-major:2")

  fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image_raw "$dir" 'unbound-distroless' "$fakemajor"
  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T8: a major bump was deployed without ALLOW_MAJOR"
  grep -qi 'major version bump' <<<"$out" \
    || fail "T8: the run failed, but not at the major-version guard: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "T8: production moved to a new major version"

  # And the guard is a guard, not a wall: ALLOW_MAJOR=1 lets the bump past
  # the version guard. This test image is unsigned too, though (registry_up
  # never signs anything it serves), and the cosign gate sits right after
  # the major-version guard — deliberately, since there is no point
  # verifying the signature of something already refused. So this half
  # cannot reach a successful deployment: it dies one guard further in.
  # Assert that precisely: the major-version message is gone and the
  # cosign failure is what's left, per the brief's own note on this case.
  rc=0
  out=$(updater_run "$dir" ALLOW_MAJOR=1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T8: ALLOW_MAJOR=1 unexpectedly succeeded against an unsigned image"
  grep -qi 'major version bump' <<<"$out" \
    && fail "T8: ALLOW_MAJOR=1 was still refused at the major-version guard: $out"
  grep -qi 'cosign verification FAILED' <<<"$out" \
    || fail "T8: ALLOW_MAJOR=1 failed, but not at the cosign gate: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "T8: production changed even though the bump was never actually deployed"
  pass "T8: major bump refused by default; ALLOW_MAJOR=1 passes the version guard and is stopped only by the cosign gate"
}

t_self_update_applies() {
  # The sidecar's own services are declared on a throwaway-registry tag. A
  # newer, key-signed image appears under that tag; at the end of an
  # up-to-date cycle the sidecar must verify it and hand the recreation to
  # an ephemeral helper running the NEW image, because a `compose up` run
  # from inside the container being replaced dies when Compose stops it.
  local dir="$TEST_TMPDIR/upd-selfup-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 v2
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local id1; id1=$(fixture_service_image_id "$dir" updater)
  [ -n "$id1" ] || fail "setup: updater service not running"

  # Same tag, new bits, signed with the test key.
  v2=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"2\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"
  local id2; id2=$(docker image inspect "$v2" --format '{{.Id}}')
  [ "$id1" != "$id2" ] || fail "setup: v1 and v2 have the same image id"

  local out
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "cycle with a pending self-update failed: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not launched: $out"

  local _i
  for _i in $(seq 1 30); do
    [ "$(fixture_service_image_id "$dir" updater)" = "$id2" ] \
      && [ "$(fixture_service_image_id "$dir" metrics)" = "$id2" ] && break
    sleep 3
  done
  [ "$(fixture_service_image_id "$dir" updater)" = "$id2" ] || fail "updater service is not on the new image after 90s"
  [ "$(fixture_service_image_id "$dir" metrics)" = "$id2" ] || fail "metrics service is not on the new image after 90s"
  sleep 3
  [ -z "$(docker ps -aq --filter label=unbound-autoupdate.helper=1)" ] || fail "the apply helper container was left behind"
  updater_exec "$dir" grep -q '^SELF_UPDATE_TS=[0-9]' /var/lib/unbound-autoupdate/state.env \
    || fail "SELF_UPDATE_TS not recorded"
  updater_exec "$dir" grep -qE '^unbound_autoupdate_self_update_last_timestamp_seconds [0-9]{10}$' /var/lib/unbound-autoupdate/metrics.prom \
    || fail "metrics.prom does not reflect the self-update"
  pass "self-update: a key-signed newer sidecar image is applied to both services by the ephemeral helper"
}

t_self_update_rolls_back() {
  # The newer image is signed and pulls fine, but the updater container
  # built from it dies at start: its entrypoint no longer knows the fixture's
  # `idle` mode. The breakage is deliberately confined to that mode so the
  # helper (which runs on the same new image, in self-update-apply mode) and
  # the metrics service both work — this test is about the helper noticing
  # a dead sidecar, pinning both services back to the previous digest, and
  # quarantining the new digest so the next cycle does not try again.
  local dir="$TEST_TMPDIR/upd-selfrb-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 v2
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local id1; id1=$(fixture_service_image_id "$dir" updater)

  v2=$(registry_publish "FROM $UPDATER_IMAGE
RUN sed -i 's/^  idle)\$/  idle-gone)/' /usr/local/bin/entrypoint.sh
LABEL test.selfupdate=\"broken\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"
  local d2; d2=$(docker image inspect "$v2" --format '{{index .RepoDigests 0}}')

  local out
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "cycle failed before launching the helper: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not launched: $out"

  # The helper waits up to 30 s before rolling back; give it time.
  local _i
  for _i in $(seq 1 40); do
    updater_exec "$dir" grep -q "^SELF_QUARANTINE_DIGEST=$d2\$" /var/lib/unbound-autoupdate/state.env 2>/dev/null && break
    sleep 3
  done
  updater_exec "$dir" grep -q "^SELF_QUARANTINE_DIGEST=$d2\$" /var/lib/unbound-autoupdate/state.env \
    || fail "the broken sidecar image was not quarantined: $(updater_exec "$dir" cat /var/lib/unbound-autoupdate/state.env 2>/dev/null)"
  [ "$(fixture_service_image_id "$dir" updater)" = "$id1" ] || fail "updater service was not rolled back to the previous image"
  [ "$(fixture_service_image_id "$dir" metrics)" = "$id1" ] || fail "metrics service was not rolled back to the previous image"
  updater_exec "$dir" grep -q '^unbound_autoupdate_quarantine_active{axis="self"} 1$' /var/lib/unbound-autoupdate/metrics.prom \
    || fail "metrics.prom does not show the self quarantine"
  # And the next cycle must deliberately leave it alone.
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "cycle after a self-rollback failed: $out"
  grep -q 'quarantined after a failed self-update' <<<"$out" || fail "quarantined sidecar image was retried: $out"
  pass "self-update: a sidecar image that cannot start is rolled back on both services and quarantined"
}

t_modes() {
  local dir="$TEST_TMPDIR/upd-modes-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$OLD_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image "$dir" "$MOVING_REF"
  # check mode validates everything but must never swap.
  local out
  out=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
        -f "$dir/docker-compose.yml" exec -T updater \
        /usr/local/bin/entrypoint.sh check 2>&1) || fail "check mode failed: $out"
  grep -q 'check mode' <<<"$out" || fail "check mode did not announce itself: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "check mode swapped production"
  pass "check mode validates the update without deploying it"

  out=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
        -f "$dir/docker-compose.yml" exec -T updater \
        /usr/local/bin/entrypoint.sh once 2>&1) || fail "once mode failed: $out"
  [ "$(running_ref "$dir")" != "$before" ] || fail "once mode did not deploy"
  pass "once mode runs exactly one cycle and deploys"

  # An unknown mode is a hard, named error — not a silent loop.
  local rc=0
  out=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$UPDATER_IMAGE" bogus 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown mode was accepted"
  grep -q "unknown mode 'bogus'" <<<"$out" || fail "unknown mode not named: $out"
  # The image carries the version it was built with.
  out=$(docker run --rm --entrypoint cat "$UPDATER_IMAGE" /usr/local/lib/unbound-autoupdate/VERSION)
  [ -n "$out" ] || fail "VERSION file is empty"
  pass "unknown mode refused by name; VERSION file present ($out)"
}

t_loop_sigterm() {
  # loop mode sleeps between cycles; SIGTERM must interrupt that sleep, or
  # every `docker compose down` waits for Docker's 10 s kill timeout. The
  # container here is not compose-managed, so its first cycle fails fast
  # (discovery) and the loop goes to sleep — which is exactly what we stop.
  local name="upd-sigterm-$$" t0 t1
  docker run -d --name "$name" -e INTERVAL=1h -v /var/run/docker.sock:/var/run/docker.sock "$UPDATER_IMAGE" loop >/dev/null
  blocker_track "$name"
  sleep 6
  docker logs "$name" 2>&1 | grep -q 'next cycle in' || fail "loop did not reach its sleep: $(docker logs "$name" 2>&1 | tail -5)"
  t0=$(date +%s); docker stop "$name" >/dev/null; t1=$(date +%s)
  [ $(( t1 - t0 )) -lt 4 ] || fail "docker stop took $(( t1 - t0 ))s — SIGTERM is not reaching the sleep"
  docker rm -f "$name" >/dev/null 2>&1 || true
  pass "loop mode stops in under 4 s on SIGTERM"
}

t_metrics_scrape() {
  local dir="$TEST_TMPDIR/upd-metrics-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"

  local addr out="$TEST_TMPDIR/upd-metrics-$$.prom" _i
  # An up-to-date cycle never queries production, and unbound prints no
  # num.query.type.* key at all for a type it has never seen. Ask the
  # resolver something real first, or the per-type and per-rcode assertions
  # below would be asserting the absence of traffic rather than the exporter.
  for _i in $(seq 1 5); do
    updater_exec "$dir" dig +time=5 +tries=2 @unbound example.com A 2>/dev/null \
      | grep -q 'status: NOERROR' && break
    [ "$_i" -lt 5 ] || fail "the fixture resolver never answered a query — the scrape would carry no per-type statistics"
    sleep 3
  done
  addr=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" port metrics 9167)
  [ -n "$addr" ] || fail "metrics service publishes no port"
  for _i in $(seq 1 15); do
    curl -fsS -o "$out" "http://$addr/metrics" 2>/dev/null && break
    sleep 1
  done
  [ -s "$out" ] || fail "/metrics never answered on $addr: $(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" logs metrics 2>&1 | tail -5)"
  promtool_check "$out" || fail "/metrics rejected by promtool: $(head -40 "$out")"
  local expect
  for expect in \
    '^unbound_exporter_scrape_success 1$' \
    '^unbound_exporter_scrape_duration_seconds [0-9.]+$' \
    '^unbound_queries_total [0-9]+$' \
    '^unbound_query_types_total{type="A"} [0-9]+$' \
    '^unbound_response_time_seconds_bucket{le="\+Inf"} [0-9]+$' \
    '^unbound_time_up_seconds [0-9.]+$' \
    '^unbound_autoupdate_last_cycle_status{status="up_to_date"} 1$' \
    '^unbound_autoupdate_cycles_total{status="up_to_date"} 1$' \
    '^unbound_autoupdate_target_image_info{digest="esitcparis/unbound-distroless@sha256:'; do
    grep -qE "$expect" "$out" || fail "/metrics: missing '$expect' in: $(head -60 "$out")"
  done
  pass "/metrics serves unbound statistics and sidecar cycle metrics, promtool-clean"

  # The resolver stopped: the scrape must still answer 200 with the sidecar
  # metrics and say the unbound part failed — never a 5xx or a hang.
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" stop unbound >/dev/null 2>&1
  local code
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 20 "http://$addr/metrics")
  [ "$code" = 200 ] || fail "/metrics returned HTTP $code with the resolver down"
  grep -q '^unbound_exporter_scrape_success 0$' "$out" || fail "scrape_success not 0 with the resolver down: $(head -20 "$out")"
  grep -q '^unbound_autoupdate_last_cycle_status' "$out" || fail "sidecar metrics missing with the resolver down"
  promtool_check "$out" || fail "degraded /metrics rejected by promtool"
  rm -f "$out"
  pass "/metrics degrades to scrape_success=0 with HTTP 200 when the resolver is down"
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

t1b_moved_tag_update_actually_lands() {
  # T1 rewrites the compose file's image STRING, which alone changes
  # Compose's service config hash and guarantees recreation regardless of
  # how Compose treats a moved tag. Nobody edits the compose file in
  # production: the string stays "$MOVING_REF" and the TAG MOVES underneath
  # it. This is the scenario T1 cannot see, and the one that actually matters.
  local dir="$TEST_TMPDIR/upd-t1b-$$"
  trap 'fixture_destroy "$dir"' RETURN

  # Point $MOVING_REF's LOCAL tag at the older digest so the fixture starts
  # on it — without the compose file ever mentioning anything but
  # "$MOVING_REF". retag_track (not this function's own RETURN trap) is what
  # guarantees the host's real tag gets restored even if a setup assertion
  # below trips: fail() calls `exit`, which skips a `trap ... RETURN`, but
  # not the suite-wide EXIT-time reaper that consults _MOVED_TAGS.
  docker pull -q "$OLD_REF" >/dev/null
  local old_id; old_id=$(docker image inspect "$OLD_REF" --format '{{.Id}}')
  docker tag "$old_id" "$MOVING_REF"
  retag_track "$MOVING_REF"

  fixture_create "$dir" "$MOVING_REF"
  local before; before=$(running_ref "$dir")
  [ "$before" = "$old_id" ] || fail "T1b setup: fixture did not start on the retagged old digest ($before != $old_id)"

  # The registry now serves a newer digest under the SAME tag. The compose
  # file is never touched.
  updater_run "$dir" || fail "T1b: cycle failed"

  local after declared
  after=$(running_ref "$dir")
  docker pull -q "$MOVING_REF" >/dev/null
  declared=$(docker image inspect "$MOVING_REF" --format '{{.Id}}')

  [ "$after" != "$before" ] || fail "T1b: the container is still on the old image — a moved tag with an untouched compose file was a no-op"
  [ "$after" = "$declared" ] || fail "T1b: running image ($after) is not the declared image ($declared)"
  pass "T1b: a moved tag lands even when the compose file itself is never edited"
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

t7a_failed_swap_is_loud() {
  local dir="$TEST_TMPDIR/upd-t7a-$$" blocker="upd-t7a-blocker-$$" port=15353
  # blocker_track (not just this trap) guarantees the port-holder dies even
  # if a setup assertion below calls fail(): fail()'s `exit` skips this
  # RETURN trap, and this test occupies a real DNS port on the host for its
  # duration — a container left holding it breaks every later run, on this
  # suite or any other, that needs that port.
  trap 'docker rm -f "$blocker" >/dev/null 2>&1 || true; fixture_destroy "$dir"' RETURN

  # An authentic canary-green / production-red failure. Publishing a host
  # port is the ONE axis on which a canary and production genuinely differ
  # — the canary never publishes one — so it is the only way to stage a swap
  # failure a green canary cannot predict. Nothing here is simulated: the
  # canary really passes, `compose up -d` really fails, and it fails for a
  # reason the updater had no way to see coming.
  #
  # The port is published only by the UPDATE (added below, alongside the
  # image bump, exactly as an operator would publish a port in the same edit
  # that ships a new release), and the blocker takes it BEFORE the cycle
  # starts, while it is still genuinely free. That ordering is what makes the
  # conflict deterministic, and it cannot be done the other way round: a
  # resolver publishing the port from the start holds it until the swap stops
  # it, and Docker refuses any overlapping publish in the meantime (a
  # wildcard bind conflicts with an existing loopback one), so the port could
  # only be stolen inside `compose up -d`'s own stop-old/start-new window.
  # That is a race, and an earlier revision of this test lost it reliably.
  fixture_create "$dir" "$OLD_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"

  docker run -d --name "$blocker" -p "127.0.0.1:${port}:53/udp" --entrypoint /bin/sh \
    "$UPDATER_IMAGE" -c 'sleep 3600' >/dev/null || fail "T7a setup: could not take the port"
  blocker_track "$blocker"

  fixture_set_image "$dir" "$MOVING_REF"
  # Anchored on the (now updated) image line, which — unlike the volumes: key
  # — is unique to the unbound service, so the updater's own block is left
  # alone.
  sed -i.bak "s|^    image: .*unbound-distroless.*|&\\
    ports:\\
      - \"127.0.0.1:${port}:53/udp\"|" "$dir/docker-compose.yml"
  rm -f "$dir/docker-compose.yml.bak"

  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T7a: a failed swap reported success"
  # The cycle must have died AT THE SWAP, on the conflict this test staged —
  # not at some earlier gate, which would leave everything below proving
  # nothing whatsoever about the swap path.
  grep -q 'docker compose up failed while swapping' <<<"$out" \
    || fail "T7a: the cycle failed, but not at the swap — the test proves nothing: $out"
  grep -q 'port is already allocated' <<<"$out" \
    || fail "T7a: the swap failed for some reason other than the staged port conflict: $out"

  # Whatever the recovery manages to achieve, production must never be left
  # running the image whose swap just failed.
  local declared after
  docker pull -q "$MOVING_REF" >/dev/null
  declared=$(docker image inspect "$MOVING_REF" --format '{{.Id}}')
  after=$(running_ref "$dir" 2>/dev/null || true)
  [ "$after" != "$declared" ] || fail "T7a: production is running the image whose swap failed"

  # The rollback cannot bind the port either — the compose file still
  # declares it and the blocker still holds it — so this cycle ends with
  # nothing serving DNS at all. That is exactly what the critical branch is
  # for, and reaching it is the point of this test: a swap that leaves no
  # working resolver has to say so, in the loudest terms available.
  #
  # This assertion is also the regression guard for the compose-file-list bug
  # this test found. While COMPOSE_FILE_ARGS was silently empty, the rollback
  # ran with the override as its ONLY -f, so it recreated production from a
  # bare `image:` definition — no published port, and therefore nothing to
  # conflict with. It started happily and the cycle reported "rollback
  # successful", with production quietly stripped of its state volume, its
  # configuration and its capability limits. If that ever comes back, this
  # grep fails.
  grep -q 'MANUAL INTERVENTION REQUIRED' <<<"$out" \
    || fail "T7a: a swap that left no working resolver did not raise the critical notification: $out"
  pass "T7a: a swap blocked by the environment fails loudly instead of silently"
}

t7b_rollback_restores_previous_digest() {
  local dir="$TEST_TMPDIR/upd-t7b-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$OLD_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image "$dir" "$MOVING_REF"
  local rc=0 out1
  out1=$(updater_run "$dir" _TEST_FORCE_POSTSWAP_FAIL=1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T7b: a forced post-swap failure reported success"
  # Without this, every assertion below passes vacuously whenever the cycle
  # dies BEFORE the swap: production is then untouched, so it trivially still
  # runs the previous digest with its mounts intact and a working resolver,
  # and nothing has been proved about the rollback at all.
  grep -q 'post-swap validation failed — rolling back' <<<"$out1" \
    || fail "T7b: the forced cycle never reached the rollback — nothing below would prove anything: $out1"

  local after; after=$(running_ref "$dir")
  [ "$after" = "$before" ] || fail "T7b: rollback did not restore the previous image ($after != $before)"

  # Restoring the previous image is only half of it: the rest of the service
  # definition has to survive too. This is the direct regression guard for the
  # compose-file-list bug — the rollback override must be merged ON TOP of the
  # project's own compose file, never used as a replacement for it. When it
  # was used as a replacement, production came back from a bare `image:`
  # definition: no state volume (so the DNSSEC trust anchor was gone) and no
  # bind-mounted unbound.conf (so it silently served the image's built-in
  # defaults instead of the operator's configuration) — and the cycle still
  # called that "rollback successful".
  local mounts
  mounts=$(docker inspect "$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
           -f "$dir/docker-compose.yml" ps -q unbound)" --format '{{range .Mounts}}{{.Destination}} {{end}}')
  grep -q '/var/lib/unbound' <<<"$mounts" \
    || fail "T7b: the rolled-back container lost its named state volume: [$mounts]"
  grep -q '/etc/unbound/unbound.conf' <<<"$mounts" \
    || fail "T7b: the rolled-back container lost its bind-mounted configuration: [$mounts]"

  # And the resolver still works after the rollback.
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    discover_target
    ip=$(target_probe_ip)
    wait_resolver "$ip" 90 && validate_resolver "$ip" && echo OK') || fail "resolver broken after rollback: $out"
  grep -q '^OK$' <<<"$out" || fail "T7b: resolver does not validate after rollback: $out"

  # The failing digest must now be quarantined: the next cycle must refuse it
  # DELIBERATELY. Asserting only that the container was not recreated is not
  # enough — anything that stops a cycle short satisfies that, including a
  # crash, so the assertion has to name the reason. It caught two real bugs
  # this way: an unchanged container id alone passed happily both while the
  # rollback pin was leaking into the next cycle's compose file list (making
  # every later cycle report "up to date" and never reach this check at all)
  # and with quarantine_set deleted outright.
  local cid_before cid_after rc2=0 out2
  cid_before=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  out2=$(updater_run "$dir" 2>&1) || rc2=$?
  [ "$rc2" -eq 2 ] \
    || fail "T7b: the cycle after a rollback did not deliberately skip (expected exit 2, got $rc2): $out2"
  grep -q 'is quarantined after a failed deployment' <<<"$out2" \
    || fail "T7b: the cycle was skipped, but not by the quarantine: $out2"
  cid_after=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  [ "$cid_before" = "$cid_after" ] || fail "T7b: the quarantined image was retried immediately"
  pass "T7b: rollback restores the previous digest, resolver validates, digest quarantined"
}

ALL_TESTS="
  t0_image_sane
  t0_state_unit
  t0_logfmt_unit
  t0_compose_file_args_unit
  t0_notify_host_unit
  t0_config_fingerprint_directory_unit
  t0_stats_to_prometheus_unit
  t0_cycle_metrics_unit
  t_discover
  t_config_fingerprint_handles_spaces
  t_validate
  t_validate_dnssec_optional
  t4_invalid_conf_rejected
  t5_healthcheck_breaking_conf
  t_canary_lifecycle
  t_canary_replicates_declared_runtime
  t_canary_refused_in_host_network_mode
  t_modes
  t_loop_sigterm
  t_metrics_scrape
  t1_image_update_actually_lands
  t1b_moved_tag_update_actually_lands
  t2_noop_second_cycle
  t3_config_change_triggers
  t_verify_key_accepts_signed
  t6_unsigned_image_refused
  t8_major_bump_refused
  t_self_update_applies
  t_self_update_rolls_back
  t7a_failed_swap_is_loud
  t7b_rollback_restores_previous_digest
"
# ONLY="t_a t_b" runs a subset while iterating on one test; the default is
# the whole suite, which is what CI runs.
for t in ${ONLY:-$ALL_TESTS}; do
  info "$t"
  "$t"
done
echo "ALL UPDATER TESTS PASSED"
