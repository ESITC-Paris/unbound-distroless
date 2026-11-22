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
  # The shipped code reads no test variable: the one hook the suite needs is
  # added only to its own derived image (hooks_image).
  if docker run --rm --entrypoint /bin/sh "$UPDATER_IMAGE" -c 'grep -rq "_TEST_" /usr/local/bin/unbound-autoupdate /usr/local/bin/entrypoint.sh /usr/local/lib/unbound-autoupdate'; then
    fail "the image ships a test hook"
  fi
  pass "image contains docker+compose+cosign+dig+bash+flock, and no test hook"
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

    # Any other unreadable file still ends the cycle (exit, not return)...
    if ( _compose_file_args "/proj/docker-compose.yml,/proj/missing.yml"; echo survived ) 2>/dev/null | grep -q survived; then
      echo "an unreadable compose file was tolerated"; exit 1
    fi
    # ...while _compose_file_paths only reports it, for self_update to skip.
    if _compose_file_paths "/proj/docker-compose.yml,/proj/missing.yml" >/dev/null 2>&1; then
      echo "_compose_file_paths accepted an unreadable file"; exit 1
    fi

    # Pins carry an immutable reference or nothing at all.
    D=0000000000000000000000000000000000000000000000000000000000000000
    write_pin_file /tmp/pin.yml "127.0.0.1:5000/unbound-x@sha256:$D" unbound metrics \
      || { echo "a valid digest reference was refused"; exit 1; }
    [ "$(cat /tmp/pin.yml)" = "$(printf "services:\n  unbound:\n    image: \"127.0.0.1:5000/unbound-x@sha256:$D\"\n  metrics:\n    image: \"127.0.0.1:5000/unbound-x@sha256:$D\"")" ] \
      || { echo "unexpected pin file:"; cat /tmp/pin.yml; exit 1; }
    for bad in "esitcparis/unbound-distroless:1" "x@sha256:abc" "$(printf "x@sha256:$D\nservices:")" "x\"@sha256:$D"; do
      if write_pin_file /tmp/pin2.yml "$bad" unbound 2>/dev/null; then echo "pinned a mutable or malformed reference: $bad"; exit 1; fi
    done
    echo OK') || fail "compose file args unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "compose file args unit did not print OK: $out"
  pass "compose file list: single, multiple, trailing separator, relative paths, rollback overrides filtered; pins accept only digest references"
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

    # A tls/ directory in the Lets Encrypt live/ layout is nothing but
    # SYMLINKS to files elsewhere. `find . -type f` skips every one of them,
    # so the mount expands to no files and a renewed certificate never moves
    # the fingerprint — silently, which is the exact case a directory mount
    # is expanded for.
    mkdir -p /real /link
    echo certA > /real/cert.pem
    ln -s /real/cert.pem /link/server.pem
    DECLARED_BIND_MOUNTS=(-v /link:/etc/unbound/tls:ro)
    s1=$(config_fingerprint 2>/dev/null) || { echo "a directory of symlinks failed to hash"; exit 1; }
    [ "$s1" != "$empty" ] || { echo "a directory of symlinks hashed as empty input"; exit 1; }
    echo certB > /real/cert.pem
    s2=$(config_fingerprint 2>/dev/null) || { echo "a directory of symlinks failed to hash after rotation"; exit 1; }
    [ "$s1" != "$s2" ] || { echo "a certificate rotated behind a symlink did not change the fingerprint"; exit 1; }

    # A directory mount that expands to nothing can never move the
    # fingerprint: that is a blind spot, not a valid hash.
    mkdir -p /emptydir
    DECLARED_BIND_MOUNTS=(-v /emptydir:/etc/unbound/tls:ro)
    if config_fingerprint >/dev/null 2>&1; then echo "an empty directory mount was hashed instead of failing"; exit 1; fi

    # A dangling symlink is a BROKEN configuration, not an absent file.
    mkdir -p /dangling
    ln -s /nowhere/missing.pem /dangling/server.pem
    DECLARED_BIND_MOUNTS=(-v /dangling:/etc/unbound/tls:ro)
    if config_fingerprint >/dev/null 2>&1; then echo "a dangling symlink was silently ignored"; exit 1; fi
    echo OK') || fail "config_fingerprint directory unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "config_fingerprint directory unit did not print OK: $out"
  pass "config_fingerprint covers directory mounts including symlinked certificates, sees renames, and fails loudly on a missing path, an empty mount or a dangling symlink"
}

t0_config_fingerprint_exclude_unit() {
  # FINGERPRINT_EXCLUDE removes a mount from change detection — a blocklist
  # the generator applies at runtime must not trigger a canary + container
  # swap (which empties the cache) — and removes NOTHING else: the other
  # mounts still move the hash, and an unset variable changes nothing.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    mkdir -p /tmp/st /bl; echo conf1 > /u.conf; echo "local-zone: \"a.\" static" > /bl/blocklist.conf
    DECLARED_BIND_MOUNTS=(-v /u.conf:/etc/unbound/unbound.conf:ro -v /bl:/etc/unbound/blocklists:ro)

    unset FINGERPRINT_EXCLUDE
    base=$(config_fingerprint)
    echo "local-zone: \"b.\" static" >> /bl/blocklist.conf
    [ "$(config_fingerprint)" != "$base" ] || { echo "without an exclusion a blocklist change was invisible"; exit 1; }

    export FINGERPRINT_EXCLUDE="/etc/unbound/blocklists/"
    h1=$(config_fingerprint)
    echo "local-zone: \"c.\" static" >> /bl/blocklist.conf
    [ "$(config_fingerprint)" = "$h1" ] || { echo "an excluded mount still moved the fingerprint"; exit 1; }

    echo conf2 > /u.conf
    [ "$(config_fingerprint)" != "$h1" ] || { echo "excluding the blocklist also hid unbound.conf"; exit 1; }

    # A path that merely starts with the excluded one is NOT under it.
    DECLARED_BIND_MOUNTS=(-v /u.conf:/etc/unbound/unbound.conf:ro -v /bl:/etc/unbound/blocklists-extra:ro)
    h2=$(config_fingerprint)
    echo "local-zone: \"d.\" static" >> /bl/blocklist.conf
    [ "$(config_fingerprint)" != "$h2" ] || { echo "a sibling path sharing the prefix was excluded"; exit 1; }
    echo OK') || fail "config_fingerprint exclude unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "config_fingerprint exclude unit did not print OK: $out"
  pass "FINGERPRINT_EXCLUDE removes only the declared data mount from change detection"
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
    '^unbound_response_time_percentile_seconds\{percentile="50"\} 3e-06$' \
    '^unbound_response_time_percentile_seconds\{percentile="95"\} 7.2e-06$' \
    '^unbound_response_time_percentile_seconds\{percentile="99"\} 7.84e-06$' \
    '^# TYPE unbound_response_time_percentile_seconds gauge$' \
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
  pass "stats_to_prometheus: valid exposition text, labels, grouped families, cumulative histogram, percentiles"
}

t0_anchor_to_prometheus_unit() {
  # The RFC 5011 file unbound keeps (root.key) must come out as the probe
  # timestamps, the failure counter and one info sample per key with its
  # state — and a file that is not one (empty, or unbound's error text) must
  # produce NOTHING rather than a value-less sample.
  local out="$TEST_TMPDIR/upd-anchor-$$.prom"
  docker run --rm -i --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    anchor_to_prometheus' > "$out" <<'ANCHOR'
; autotrust trust anchor file
;;id: . 1
;;last_queried: 1789939971 ;;Sun Sep 20 21:32:51 2026
;;last_success: 1789939971 ;;Sun Sep 20 21:32:51 2026
;;next_probe_time: 1790019521 ;;Mon Sep 21 19:38:41 2026
;;query_failed: 0
;;query_interval: 43200
;;retry_time: 8640
.	86400	IN	DNSKEY	257 3 8 AwEAAa96jeuknZlaeSrvyAJj6ZHv28hhOKkx3rmIHHqI4W+FZqOx4rrM ;{id = 38696 (ksk), size = 2048b} ;;state=2 [  VALID  ] ;;count=0 ;;lastchange=1736575223 ;;Sat Jan 11 06:00:23 2025
.	86400	IN	DNSKEY	257 3 8 AwEAAaz/tAm8yTn4Mfeh5eyI96WSVexTBAvkMgJzkKTOiW1vkIbzxeF3 ;{id = 20326 (ksk), size = 2048b} ;;state=2 [  VALID  ] ;;count=0 ;;lastchange=1536000000 ;;Mon Sep  3 18:40:00 2018
ANCHOR
  promtool_check "$out" || fail "anchor_to_prometheus output rejected by promtool: $(cat "$out")"
  local expect
  for expect in \
    '^unbound_trust_anchor_last_success_timestamp_seconds 1789939971$' \
    '^unbound_trust_anchor_next_probe_timestamp_seconds 1790019521$' \
    '^unbound_trust_anchor_failed_probes 0$' \
    '^unbound_trust_anchor_key_info\{keytag="38696",state="VALID"\} 1$' \
    '^unbound_trust_anchor_key_info\{keytag="20326",state="VALID"\} 1$' \
    '^# TYPE unbound_trust_anchor_key_info gauge$'; do
    grep -qE "$expect" "$out" || fail "anchor_to_prometheus: missing '$expect' in: $(cat "$out")"
  done
  local none
  none=$(docker run --rm -i --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    anchor_to_prometheus' <<<'Error response from daemon: No such container: unbound')
  [ -z "$none" ] || fail "anchor_to_prometheus emitted samples for a non-anchor input: $none"
  rm -f "$out"
  pass "anchor_to_prometheus: probe timestamps, failure counter, one info sample per key, silent on garbage"
}

t0_cache_split_unit() {
  # A dump must come out as self-contained load_cache inputs of at most
  # KEEP_CACHE_CHUNK entries, every record-set batch numbered before every
  # message batch (a message only loads when its record sets are cached),
  # with no entry lost or duplicated and multi-line entries kept whole.
  local out
  out=$(docker run --rm -i --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/cache.sh
    KEEP_CACHE_CHUNK=2; d=$(mktemp -d); cat > "$d/dump"
    _cache_split "$d/dump" "$d"
    for f in "$d"/0*; do printf "== %s\n" "${f##*/}"; cat "$f"; done' <<'DUMP'
START_RRSET_CACHE
;rrset 100 1 1 5 4
a.test.	100	IN	A	192.0.2.1
a.test.	100	IN	RRSIG	A 13 2 100 20260926031529 20260919020529 1 test. AAAA
;rrset 100 1 0 5 3
b.test.	100	IN	A	192.0.2.2
;rrset 100 1 0 5 3
c.test.	100	IN	A	192.0.2.3
END_RRSET_CACHE
START_MSG_CACHE
msg a.test. IN A 33152 1 100 4 1 0 0 -1
a.test. IN A 0
msg b.test. IN A 33152 1 100 3 1 0 0 -1
b.test. IN A 0
msg c.test. IN A 33152 1 100 3 1 0 0 -1
c.test. IN A 0
END_MSG_CACHE
EOF
DUMP
)
  local expect
  expect='== 000001
START_RRSET_CACHE
;rrset 100 1 1 5 4
a.test.	100	IN	A	192.0.2.1
a.test.	100	IN	RRSIG	A 13 2 100 20260926031529 20260919020529 1 test. AAAA
;rrset 100 1 0 5 3
b.test.	100	IN	A	192.0.2.2
END_RRSET_CACHE
START_MSG_CACHE
END_MSG_CACHE
EOF
== 000002
START_RRSET_CACHE
;rrset 100 1 0 5 3
c.test.	100	IN	A	192.0.2.3
END_RRSET_CACHE
START_MSG_CACHE
END_MSG_CACHE
EOF
== 000003
START_RRSET_CACHE
END_RRSET_CACHE
START_MSG_CACHE
msg a.test. IN A 33152 1 100 4 1 0 0 -1
a.test. IN A 0
msg b.test. IN A 33152 1 100 3 1 0 0 -1
b.test. IN A 0
END_MSG_CACHE
EOF
== 000004
START_RRSET_CACHE
END_RRSET_CACHE
START_MSG_CACHE
msg c.test. IN A 33152 1 100 3 1 0 0 -1
c.test. IN A 0
END_MSG_CACHE
EOF'
  [ "$out" = "$expect" ] || fail "_cache_split: unexpected batches:
$out"
  pass "cache split: bounded self-contained batches, record sets before messages, entries kept whole"
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
    # A label VALUE is a quoted string. An image digest or version label is
    # not a trusted schema, and one unescaped double quote does not corrupt a
    # single sample — it makes a Prometheus parser reject the WHOLE document,
    # losing every metric in the file at once. promtool below is the judge.
    state_set LAST_IMAGE_DIGEST "esitcparis/unbound-distroless@sha256:0000000000000000000000000000000000000000000000000000000000000000\"quote"
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
  grep -qF 'sha256:0000000000000000000000000000000000000000000000000000000000000000\"quote",version=' "$out" \
    || fail "cycle metrics: the double quote in the digest was not escaped: $(grep target_image_info "$out")"
  rm -f "$out"
  pass "record_cycle persists status and counters and writes a valid metrics.prom, label values escaped"
}

t0_helper_lock_unit() {
  # The self-update helper writes the SAME state file a cycle writes, from a
  # different container, and the sidecar it has just recreated may already be
  # running its first cycle. state_set is read-modify-write, so an interleaved
  # writer silently drops the other's keys — and the key at risk is the self
  # quarantine, without which a sidecar image that cannot start is relaunched
  # every cycle forever. The helper must therefore take the cycle lock.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st RETRY_AFTER=24h
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    . /usr/local/lib/unbound-autoupdate/selfupdate.sh
    state_init
    # A cycle is already holding the lock, as one legitimately can be.
    flock "$LOCK_FILE" sleep 4 &
    holder=$!
    sleep 0.5
    start=$(date -u +%s)
    _self_update_record_failure "repo@sha256:deadbeef"
    waited=$(( $(date -u +%s) - start ))
    wait "$holder"
    [ "$waited" -ge 3 ] || { echo "the helper wrote state after ${waited}s — it did not wait for the cycle lock"; exit 1; }
    [ "$(state_get SELF_QUARANTINE_DIGEST)" = "repo@sha256:deadbeef" ] || { echo "the quarantine key did not land"; exit 1; }
    grep -q "^unbound_autoupdate_quarantine_active{axis=\"self\"} 1$" "$METRICS_FILE" \
      || { echo "metrics.prom was not rewritten"; exit 1; }
    # And the lock is released again, or the next cycle would block forever.
    flock -w 5 "$LOCK_FILE" true || { echo "the helper did not release the cycle lock"; exit 1; }

    # A cycle legitimately holds that lock for MINUTES (canary, post-swap and
    # rollback validation each wait up to 45-90 s plus their probes). When the
    # wait runs out the helper must still write: an unlocked write risks a torn
    # state.env that the next cycle rewrites, while a missing quarantine
    # GUARANTEES the broken image is relaunched on every cycle, silently. So
    # the timeout is loud and non-fatal, never an exit.
    flock "$LOCK_FILE" sleep 6 &
    holder2=$!
    sleep 0.5
    start=$(date -u +%s)
    err=$( { SELF_LOCK_WAIT=2 _self_update_record_failure "repo@sha256:cafe"; } 2>&1 1>/dev/null )
    elapsed=$(( $(date -u +%s) - start ))
    wait "$holder2"
    [ "$elapsed" -lt 5 ] || { echo "the helper waited ${elapsed}s instead of giving up after SELF_LOCK_WAIT=2"; exit 1; }
    case "$err" in *"could not take the cycle lock"*) : ;; *) echo "the lock timeout was not reported: $err"; exit 1;; esac
    [ "$(state_get SELF_QUARANTINE_DIGEST)" = "repo@sha256:cafe" ] \
      || { echo "the quarantine key was dropped when the lock could not be taken"; exit 1; }
    echo OK') || fail "helper lock unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "helper lock unit did not print OK: $out"
  pass "the self-update helper waits for the cycle lock, releases it, and still writes state when the wait runs out"
}

t0_self_swap_identity_unit() {
  # `compose up` exiting 0 is not proof it recreated anything. A Compose that
  # declines to recreate leaves the OLD container in place — running, never
  # restarted, and therefore perfectly acceptable to _self_services_healthy —
  # after which the helper clears the quarantine, stamps SELF_UPDATE_TS and
  # notifies "updated" while nothing whatsoever changed: a false "updated"
  # every cycle, forever. And a container that genuinely IS new still has to
  # run the digest verify_image approved, or a project with
  # `pull_policy: always` quietly deploys a sidecar image nobody verified.
  # Both are pure decision logic, asserted here against stub docker/compose
  # commands rather than inside the ten-minute self-update integration test.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -uo pipefail
    export STATE_DIR=/tmp/st RETRY_AFTER=1h
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    . /usr/local/lib/unbound-autoupdate/selfupdate.sh
    for f in _self_service_cids _self_services_recreated _self_services_on_image; do
      declare -F "$f" >/dev/null || { echo "missing function: $f"; exit 1; }
    done

    # The helper judges by the IMAGE ID each container runs: the identity of
    # what runs on both image stores, whatever tags or digests say.
    NEW=sha256:imgnew
    declare -A CID_OF IMG_OF

    # The only two commands these functions ask about the world.
    compose() { [ "$1" = ps ] && printf "%s\n" "${CID_OF[$3]:-}"; return 0; }
    docker() { [ "$1" = inspect ] && printf "%s\n" "${IMG_OF[$2]:-}"; return 0; }

    CID_OF[updater]=c1; CID_OF[metrics]=m1
    IMG_OF[c1]=sha256:imgold;  IMG_OF[m1]=sha256:imgold
    before=$(_self_service_cids updater metrics)

    # Nothing moved: the exact shape of a Compose that declined to recreate.
    if _self_services_recreated "$before" updater metrics; then
      echo "an untouched container was accepted as a recreation"; exit 1
    fi
    if _self_services_on_image "$NEW" updater; then
      echo "a container still on the old image was accepted as running the new digest"; exit 1
    fi

    # One service moved, the other did not: still a failure, not a partial win.
    CID_OF[updater]=c2; IMG_OF[c2]=sha256:imgnew
    if _self_services_recreated "$before" updater metrics; then
      echo "a half-finished recreation was accepted"; exit 1
    fi
    _self_services_recreated "$before" updater \
      || { echo "a genuinely recreated service was rejected"; exit 1; }
    _self_services_on_image "$NEW" updater \
      || { echo "a service running the new digest was rejected"; exit 1; }

    # Both moved, but onto an image that is NOT the verified digest — what a
    # `pull_policy: always` re-pull can land on.
    CID_OF[metrics]=m2; IMG_OF[m2]=sha256:imgold
    _self_services_recreated "$before" updater metrics \
      || { echo "two recreated services were rejected"; exit 1; }
    if _self_services_on_image "$NEW" updater metrics; then
      echo "a service recreated on an unverified digest was accepted"; exit 1
    fi

    # No running container at all (the sidecar died at start) fails both.
    CID_OF[updater]=""
    if _self_services_recreated "$before" updater; then echo "a service with no container passed the id check"; exit 1; fi
    if _self_services_on_image "$NEW" updater; then echo "a service with no container passed the image check"; exit 1; fi
    echo OK') || fail "self swap identity unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "self swap identity unit did not print OK: $out"
  pass "the self-update helper only trusts a swap it can see: a new container id AND the verified image ID running in it"
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
    echo "running=$(docker inspect "$TARGET_CONTAINER" --format "{{.Image}}")"
    echo "resolved=$(resolve_registry_digest "$DECLARED_IMAGE_REF")"
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
  grep -qE '^running=sha256:[0-9a-f]{64}$' <<<"$out" || fail "bad running image id: $out"
  grep -qE '^resolved=esitcparis/unbound-distroless@sha256:[0-9a-f]{64}$' <<<"$out" \
    || fail "the declared tag was not resolved to a registry digest of the declared repository: $out"
  # The one variable nothing used to assert — which is exactly why it could
  # sit permanently empty (Bug A) while every other check here still passed.
  # Everything downstream papers over an empty list, because Compose then
  # discovers the file from --project-directory by itself; only the rollback,
  # which adds a second -f, ever noticed.
  grep -q "^composefiles=-f $dir/docker-compose.yml\$" <<<"$out" \
    || fail "COMPOSE_FILE_ARGS was not derived from the compose label: $out"
  pass "discovery derives service, workdir, declared ref, volume, bind mounts, compose file args; a sibling on the sidecar's own image is never a candidate"
}

t_discover_waits_for_recreating_resolver() {
  # The window where `docker compose up` has removed the resolver and not yet
  # started the new one is a NORMAL restart, not a failed update. Discovery
  # must wait it out (DISCOVER_WAIT) instead of dying — dying makes the EXIT
  # trap record a failed cycle and pages the operator. Observed in production
  # 2026-09-21: one host out of three, purely on timing.
  local dir="$TEST_TMPDIR/upd-discwait-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"

  # Stop the resolver, then bring it back from the outside while a discovery
  # with DISCOVER_WAIT is already running: it must succeed.
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" stop unbound >/dev/null 2>&1
  ( sleep 6; docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" start unbound >/dev/null 2>&1 ) &
  local bg=$!
  local out rc=0
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    DISCOVER_WAIT=45 discover_target_container
    echo "service=$TARGET_SERVICE"') || rc=$?
  wait "$bg" 2>/dev/null || true
  [ "$rc" = 0 ] || fail "discovery gave up on a resolver that came back: $out"
  grep -q '^service=unbound$' <<<"$out" || fail "discovery did not settle on the resolver: $out"

  # Without the wait, the same absence must still fail fast — the metrics
  # scrape depends on that (a scrape may never block).
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" stop unbound >/dev/null 2>&1
  local t0 t1
  t0=$(date +%s)
  if updater_exec "$dir" /bin/bash -c '
      . /usr/local/lib/unbound-autoupdate/log.sh
      . /usr/local/lib/unbound-autoupdate/state.sh
      . /usr/local/lib/unbound-autoupdate/discover.sh
      discover_target_container' >/dev/null 2>&1; then
    fail "discovery found a resolver that is stopped"
  fi
  t1=$(date +%s)
  [ $(( t1 - t0 )) -lt 15 ] || fail "discovery without DISCOVER_WAIT took $(( t1 - t0 ))s — a scrape would block"
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" start unbound >/dev/null 2>&1
  pass "discovery waits out a resolver being recreated, and still fails fast without DISCOVER_WAIT"
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
  operator_compose "$dir" up -d --force-recreate unbound >/dev/null 2>&1

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
    verify_image '$signed' resolver 2>/tmp/err || { echo 'signed image refused:'; cat /tmp/err; exit 1; }
    if verify_image '$unsigned' resolver 2>/tmp/err; then echo 'unsigned image accepted'; exit 1; fi
    grep -qiE 'no signatures found|no matching signatures' /tmp/err || { echo 'refusal is not about signatures:'; cat /tmp/err; exit 1; }
    # An unreadable key file must be a clear refusal, never a fall-through to keyless.
    if COSIGN_PUBLIC_KEY=/does/not/exist verify_image '$signed' resolver 2>/tmp/err; then echo 'missing key file was ignored'; exit 1; fi
    grep -q 'not readable' /tmp/err || { echo 'missing key not reported:'; cat /tmp/err; exit 1; }
    echo OK") || fail "key verification: $out"
  grep -q '^OK$' <<<"$out" || fail "key verification did not reach OK: $out"

  # One image record can carry SEVERAL repository digests: the same bits
  # pushed under a second repository add a second RepoDigests entry to the
  # very same record. `index .RepoDigests 0` then returns whichever
  # repository happens to be listed first, which need not be the one the
  # compose file declares — and that digest is what gets compared against
  # what runs and handed to cosign. Assert the declared repository's own
  # entry comes back. The registry is already up here, so the second push
  # costs nothing; "unbound-keyed" sorts before "unbound-twin", so a naive
  # index 0 lands on the wrong one.
  local twin="$REGISTRY_HOST/unbound-twin:1"
  docker pull -q "$signed" >/dev/null
  docker tag "$signed" "$twin"
  docker push -q "$twin" >/dev/null
  docker image rm "$signed" "$twin" >/dev/null 2>&1 || true
  fixture_set_image_raw "$dir" 'unbound-distroless' "$twin"
  operator_compose "$dir" up -d unbound >/dev/null 2>&1 \
    || fail "could not redeploy the resolver on the twin-tagged image"
  local dd
  dd=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    discover_target
    echo "declared=$(resolve_registry_digest "$DECLARED_IMAGE_REF")"
    echo "running=$(describe_image "$(docker inspect "$TARGET_CONTAINER" --format "{{.Image}}")" "$(_image_repo "$DECLARED_IMAGE_REF")")"' 2>&1) \
    || fail "discovery failed on a multi-repository image: $dd"
  grep -q "^declared=$REGISTRY_HOST/unbound-twin@sha256:" <<<"$dd" \
    || fail "the declared tag resolved to a repository other than the declared one: $dd"
  grep -q "^running=$REGISTRY_HOST/unbound-twin@sha256:" <<<"$dd" \
    || fail "the running image was described by a repository other than the declared one: $dd"

  pass "verify_image: key mode accepts a key-signed image, refuses an unsigned one with cosign's reason, refuses a missing key; digests come from the DECLARED repository when an image carries several"
}

t6_unsigned_image_refused() {
  local dir="$TEST_TMPDIR/upd-t6-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  # Same bits as a real release, but pushed to a registry we control and
  # therefore never signed by the release pipeline. It must not reach production.
  #
  # The LABEL is what makes this image DISTINCT from its base on every image
  # store. With a FROM-only Dockerfile the classic graphdriver store gives the
  # build the base's own image id, and pushing then merely adds a second entry
  # to that one image record's RepoDigests — so the declared and the running
  # reference resolve to the same record, the cycle reports "up to date", exits
  # 0, and the cosign gate this test exists to exercise is never reached. The
  # containerd store yields a distinct manifest and hid the hole locally.
  local fake
  fake=$(registry_publish "FROM $MOVING_REF
LABEL test.unsigned=\"1\"" "unbound-unsigned:1")

  fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image_raw "$dir" 'unbound-distroless' "$fake"
  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T6: an unsigned image was accepted: $out"
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
  # Key mode verifies the resolver already running too, so it must be signed
  # with the test key (signed_resolver_fixture).
  FIXTURE_UPDATER_IMAGE="$v1" signed_resolver_fixture "$dir" "unbound-selfup:1"
  [ "$(service_label "$dir" updater test.selfupdate)" = 1 ] || fail "setup: updater service not running v1"
  # Container ids, not just image ids: a self-update that reported success
  # without Compose actually recreating anything is the failure mode the
  # helper's identity gate exists to catch, and only the id can see it.
  local cid_u_before cid_m_before
  cid_u_before=$(fixture_service_cid "$dir" updater)
  cid_m_before=$(fixture_service_cid "$dir" metrics)
  [ -n "$cid_u_before" ] && [ -n "$cid_m_before" ] || fail "setup: sidecar services have no containers"

  # Same tag, new bits, signed with the test key.
  v2=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"2\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"

  local out
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 SELF_LOCK_WAIT=777 2>&1) \
    || fail "cycle with a pending self-update failed: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not launched: $out"

  # SELF_LOCK_WAIT is documented as user-settable, and it is the HELPER that
  # waits for the cycle lock — an operator who tunes it on the sidecar has
  # tuned nothing at all unless it is forwarded. Catch the helper while it is
  # alive: it soaks the new sidecar for 30 s, so the window is wide.
  local _i helper=""
  for _i in $(seq 1 30); do
    helper=$(docker ps -q --filter label=unbound-autoupdate.helper=1 | head -1)
    [ -n "$helper" ] && break
    sleep 1
  done
  [ -n "$helper" ] || fail "the apply helper was never seen running"
  docker inspect "$helper" --format '{{.Config.Env}}' | grep -q 'SELF_LOCK_WAIT=777' \
    || fail "the helper did not inherit SELF_LOCK_WAIT: $(docker inspect "$helper" --format '{{.Config.Env}}')"

  for _i in $(seq 1 30); do
    [ "$(service_label "$dir" updater test.selfupdate)" = 2 ] \
      && [ "$(service_label "$dir" metrics test.selfupdate)" = 2 ] && break
    sleep 3
  done
  [ "$(service_label "$dir" updater test.selfupdate)" = 2 ] || fail "updater service is not on the new image after 90s"
  [ "$(service_label "$dir" metrics test.selfupdate)" = 2 ] || fail "metrics service is not on the new image after 90s"
  # Both services must be on NEW CONTAINERS, not merely on containers that
  # happen to report the new image: Compose declining to recreate is exactly
  # the case the helper must refuse to call a successful self-update.
  [ "$(fixture_service_cid "$dir" updater)" != "$cid_u_before" ] \
    || fail "the updater service kept its container across the self-update"
  [ "$(fixture_service_cid "$dir" metrics)" != "$cid_m_before" ] \
    || fail "the metrics service kept its container across the self-update"
  sleep 3
  [ -z "$(docker ps -aq --filter label=unbound-autoupdate.helper=1)" ] || fail "the apply helper container was left behind"
  updater_exec "$dir" grep -q '^SELF_UPDATE_TS=[0-9]' /var/lib/unbound-autoupdate/state.env \
    || fail "SELF_UPDATE_TS not recorded"
  updater_exec "$dir" grep -qE '^unbound_autoupdate_self_update_last_timestamp_seconds [0-9]{10}$' /var/lib/unbound-autoupdate/metrics.prom \
    || fail "metrics.prom does not reflect the self-update"
  # The helper deployed with the operator's own files: a plain `up -d` now
  # must not recreate the sidecar, the metrics endpoint or the resolver —
  # nor after two more, ordinary, cycles on the new sidecar.
  compose_up_is_noop "$dir" || fail "after a self-update, a plain 'docker compose up -d' recreated containers"
  registry_forward "$dir"
  local _n
  for _n in 1 2; do
    out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "idle cycle $_n after the self-update failed: $out"
    local_names_intact "$v1" "$SIGNED_RESOLVER" || fail "after idle cycle $_n following a self-update a local name is gone"
    compose_up_is_noop "$dir" || fail "after idle cycle $_n following a self-update, 'up -d' recreated containers"
  done

  # A helper from an earlier cycle may still be at work. A second one would
  # run `compose up` on the very services the first is still waiting on, so a
  # cycle that sees one must skip its own self-update entirely — even with a
  # genuinely newer, signed image available. The relay lives in the sidecar
  # container, which the self-update just replaced, so it has to be re-armed
  # before the registry is reachable from inside it again.
  registry_forward "$dir"
  local blocker="upd-selfup-helper-$$"
  blocker_track "$blocker"
  docker run -d --name "$blocker" --label unbound-autoupdate.helper=1 \
    --entrypoint sleep "$UPDATER_IMAGE" 300 >/dev/null
  local v3
  v3=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"3\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v3"
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) \
    || fail "cycle with a helper still running failed: $out"
  grep -q 'a helper is still running' <<<"$out" \
    || fail "a second helper was launched while one was still running: $out"
  [ "$(service_label "$dir" updater test.selfupdate)" = 2 ] \
    || fail "the sidecar moved again while a helper was still running"
  [ "$(docker ps -q --filter label=unbound-autoupdate.helper=1 | wc -l)" -eq 1 ] \
    || fail "a second apply helper was started"
  docker rm -f "$blocker" >/dev/null
  pass "self-update: a key-signed newer sidecar image is applied to both services by the ephemeral helper, and no second helper is ever launched"
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
  FIXTURE_UPDATER_IMAGE="$v1" signed_resolver_fixture "$dir" "unbound-selfrb:1"

  v2=$(registry_publish "FROM $UPDATER_IMAGE
RUN sed -i 's/^  idle)\$/  idle-gone)/' /usr/local/bin/entrypoint.sh
LABEL test.selfupdate=\"broken\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"
  local d2; d2=$(registry_digest "$v2")

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
  [ "$(service_label "$dir" updater test.selfupdate)" = 1 ] || fail "updater service was not rolled back to the previous image"
  [ "$(service_label "$dir" metrics test.selfupdate)" = 1 ] || fail "metrics service was not rolled back to the previous image"
  # Back on v1 under the operator's tag: a plain `up -d` keeps it.
  compose_up_is_noop "$dir" || fail "after a self-update rollback, a plain 'docker compose up -d' recreated containers"
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
  # Fetched from inside the fixture network (the sidecar has curl), not via
  # the published port: the suite may drive a remote daemon (DOCKER_HOST),
  # whose published ports are not on this host's loopback.
  for _i in $(seq 1 15); do
    updater_exec "$dir" curl -fsS http://metrics:9167/metrics > "$out" 2>/dev/null && [ -s "$out" ] && break
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
  # Timed, not just bounded by --max-time: the collection step must be under
  # ONE timeout that covers discovery as well as the exec. Bounding only the
  # exec left every `docker ps` / `docker inspect` discovery makes unbounded,
  # so a wedged daemon hung the scrape in the step before the bounded one —
  # and a scrape that hangs is worse than one that says it failed.
  local code elapsed
  code=$(updater_exec "$dir" sh -c 'curl -s -o /tmp/m.prom -w "%{http_code} %{time_total}" --max-time 20 http://metrics:9167/metrics')
  updater_exec "$dir" cat /tmp/m.prom > "$out"
  elapsed="${code#* }"; code="${code%% *}"
  [ "$code" = 200 ] || fail "/metrics returned HTTP $code with the resolver down"
  awk -v t="$elapsed" 'BEGIN { exit !(t < 15) }' \
    || fail "/metrics took ${elapsed}s with the resolver down — collection is not bounded"
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
  # _TEST_FORCE_POSTSWAP_FAIL is set on purpose: on an image built as a release
  # is built it must do NOTHING. It used to be honoured by the shipped script,
  # so anyone able to set an environment variable on the sidecar could force
  # a rollback and a quarantine of a perfectly good release.
  fixture_set_image "$dir" "$MOVING_REF"
  updater_run "$dir" _TEST_FORCE_POSTSWAP_FAIL=1 || fail "cycle failed (the test hook must be inert in a release-built image)"

  local after declared
  after=$(running_ref "$dir")
  docker pull -q "$MOVING_REF" >/dev/null
  declared=$(docker image inspect "$MOVING_REF" --format '{{.Id}}')

  [ "$after" != "$before" ] || fail "T1: the container is still on the old image — the swap was a no-op"
  [ "$after" = "$declared" ] || fail "T1: running image ($after) is not the declared image ($declared)"
  compose_up_is_noop "$dir" || fail "T1: after the sidecar's deploy, a plain 'docker compose up -d' recreated containers"
  pass "T1: after a cycle the container really runs the declared image, and 'docker compose up -d' is a no-op"
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
  compose_up_is_noop "$dir" || fail "T3: after the sidecar's deploy, a plain 'docker compose up -d' recreated containers"
  pass "T3: a configuration change is canaried and deployed, and 'docker compose up -d' is a no-op afterwards"
}

t_cache_preserved_across_swap() {
  # A swap recreates the resolver, which empties its cache. The cache of the
  # outgoing container must be carried over into the new one — and must NOT
  # be when KEEP_CACHE=0, which proves the entry below survives because of
  # the transfer and not by accident.
  local dir="$TEST_TMPDIR/upd-cache-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"

  # An entry no resolution could produce: only the transfer can bring it back.
  local seed='START_RRSET_CACHE
;rrset 86000 1 0 5 3
keep-cache.invalid.	86000	IN	A	192.0.2.55
END_RRSET_CACHE
START_MSG_CACHE
msg keep-cache.invalid. IN A 33152 1 86000 3 1 0 0 -1
keep-cache.invalid. IN A 0
END_MSG_CACHE
EOF'
  local cid round keep dump
  for round in 1 0; do
    cid=$(fixture_service_cid "$dir" unbound)
    [ "$(printf '%s\n' "$seed" | docker exec -i "$cid" /usr/local/sbin/unbound-control \
          -c /etc/unbound/unbound.conf load_cache)" = ok ] || fail "could not seed the cache"
    printf '\nserver:\n  cache-min-ttl: %s\n' "$((100 + round))" >> "$dir/unbound.conf"
    updater_run "$dir" "KEEP_CACHE=$round" >/dev/null || fail "config-change cycle failed (KEEP_CACHE=$round)"
    [ "$(fixture_service_cid "$dir" unbound)" != "$cid" ] || fail "the configuration change did not recreate the resolver"
    # Captured first: grep -q stopping early would SIGPIPE the export, and
    # pipefail would then read a present entry as absent.
    dump=$(docker exec "$(fixture_service_cid "$dir" unbound)" /usr/local/sbin/unbound-control \
      -c /etc/unbound/unbound.conf dump_cache)
    keep=0
    grep -q '^keep-cache\.invalid\.' <<<"$dump" && keep=1
    [ "$keep" = "$round" ] || fail "KEEP_CACHE=$round: seeded entry present=$keep after the swap"
  done
  pass "cache carried over a swap (and not when KEEP_CACHE=0)"
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
  # The post-swap failure is forced through the test hook, which only an image
  # in the suite's derived image only (see hooks_image, t0_image_sane, T1).
  hooks_image
  FIXTURE_UPDATER_IMAGE="$HOOKS_IMAGE" fixture_create "$dir" "$OLD_REF"
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

t0_verify_once_unit() {
  # The running image is now verified at baseline and on every hourly
  # "up to date" cycle — which must not mean asking the registry for
  # signatures every hour. A verdict is reused only for the SAME digest under
  # the SAME policy: tightening the identity or rotating the key re-judges.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -uo pipefail
    export STATE_DIR=/tmp/st
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/verify.sh
    state_init
    VERDICT=0
    cosign() { echo call >> /tmp/cosign-calls; return "$VERDICT"; }
    n() { wc -l < /tmp/cosign-calls 2>/dev/null || echo 0; }
    A="r.example/unbound@sha256:$(printf a%.0s $(seq 64))"
    B="r.example/unbound@sha256:$(printf b%.0s $(seq 64))"
    verify_image_once "$A" resolver >/dev/null && verify_image_once "$A" resolver >/dev/null || { echo "a valid image was refused"; exit 1; }
    [ "$(n)" = 1 ] || { echo "same digest, same policy: cosign asked $(n) times"; exit 1; }
    COSIGN_IDENTITY_REGEXP="^https://github.com/ESITC-Paris/unbound-distroless/.github/workflows/release.yml@.*"
    verify_image_once "$A" resolver >/dev/null; [ "$(n)" = 2 ] || { echo "a changed policy reused the old verdict"; exit 1; }
    verify_image_once "$B" resolver >/dev/null; [ "$(n)" = 3 ] || { echo "a new digest reused another digest verdict"; exit 1; }
    VERDICT=1
    if verify_image_once "$A" resolver 2>/dev/null; then echo "a refused verdict was accepted"; exit 1; fi
    [ "$(state_get VERIFIED_DIGEST)" = "$B" ] || { echo "a refusal overwrote the recorded verdict"; exit 1; }
    echo OK') || fail "verify-once unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "verify-once unit did not print OK: $out"
  pass "verify_image_once reuses a verdict only for the same digest under the same policy"
}

t0_identity_defaults_unit() {
  # The built-in signing identities are per kind of image and fully anchored:
  # the resolver only from release.yml on a vX.Y.Z-rN tag, the sidecar only
  # from updater.yml on an updater-vX.Y.Z-rN tag. The former default accepted
  # any workflow on any ref of the repository. COSIGN_IDENTITY_REGEXP, when an
  # operator sets it, still applies AS GIVEN to both kinds. What reaches
  # cosign is asserted through a stub that records its arguments; the
  # expressions themselves are matched against real and hostile identities.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -uo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/verify.sh
    cosign() { printf "%s\n" "$@" > /tmp/args; return 0; }
    idarg() { verify_image "r@sha256:x" "$1" >/dev/null 2>&1 || return 1; grep -A1 -x -- --certificate-identity-regexp /tmp/args | tail -1; }
    R=$(idarg resolver) && S=$(idarg sidecar) || { echo "a kind was refused"; exit 1; }
    [ "$R" != "$S" ] || { echo "resolver and sidecar share one identity"; exit 1; }
    if verify_image "r@sha256:x" 2>/dev/null; then echo "verify_image accepted no kind"; exit 1; fi
    G=https://github.com/ESITC-Paris/unbound-distroless/.github/workflows
    m() { printf "%s" "$2" | grep -qE "$1"; }
    for ok in "$G/release.yml@refs/tags/v1.26.2-r4" "$G/release.yml@refs/tags/v1.26.0-r0"; do
      m "$R" "$ok" || { echo "resolver identity rejects $ok"; exit 1; }
      m "$S" "$ok" && { echo "sidecar identity accepts $ok"; exit 1; }
    done
    for ok in "$G/updater.yml@refs/tags/updater-v1.0.5-r4" "$G/updater.yml@refs/tags/updater-v1.0.0-r0"; do
      m "$S" "$ok" || { echo "sidecar identity rejects $ok"; exit 1; }
      m "$R" "$ok" && { echo "resolver identity accepts $ok"; exit 1; }
    done
    for bad in "$G/release.yml@refs/heads/main" "$G/ci.yml@refs/tags/v1.26.2-r4" \
               "$G/release.yml@refs/tags/v1.26.2-r4-evil" "$G/release.yml@refs/tags/v1.26.2" \
               "https://github.com/ESITC-Paris/unbound-distroless/.github/workflows/releaseXyml@refs/tags/v1.26.2-r4" \
               "https://github.com/attacker/x/.github/workflows/a.yml@refs/heads/$G/release.yml@refs/tags/v1.26.2-r4" \
               "https://githubXcom/ESITC-Paris/unbound-distroless/.github/workflows/release.yml@refs/tags/v1.26.2-r4"; do
      m "$R" "$bad" && { echo "resolver identity accepts $bad"; exit 1; }
      m "$S" "${bad//release.yml/updater.yml}" && { echo "sidecar identity accepts a hostile variant of $bad"; exit 1; }
    done
    # An operator override keeps its documented behaviour, for both kinds.
    COSIGN_IDENTITY_REGEXP="https://github.com/my-fork/unbound-distroless/.*"
    [ "$(idarg resolver)" = "$COSIGN_IDENTITY_REGEXP" ] && [ "$(idarg sidecar)" = "$COSIGN_IDENTITY_REGEXP" ] \
      || { echo "COSIGN_IDENTITY_REGEXP no longer overrides both kinds"; exit 1; }
    echo OK') || fail "identity defaults unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "identity defaults unit did not print OK: $out"
  pass "signing identities: per kind, anchored, reject other workflows, refs and the other kind; COSIGN_IDENTITY_REGEXP still overrides both"
}

t_verify_live_identities() {
  # The defaults against what the release pipelines have ACTUALLY published
  # (read-only: cosign verify fetches signatures, it writes nothing). Current
  # and older releases must pass under their own kind, and each kind must
  # refuse the other's image — the verdict that matters for an update is
  # refusal of the wrong signer, not merely acceptance of the right one.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -uo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/verify.sh
    for r in esitcparis/unbound-distroless:latest esitcparis/unbound-distroless:1.26.1-r0; do
      verify_image "$r" resolver 2>/tmp/e || { echo "resolver $r refused:"; tail -3 /tmp/e; exit 1; }
      if verify_image "$r" sidecar 2>/dev/null; then echo "the sidecar identity accepted resolver image $r"; exit 1; fi
    done
    for r in esitcparis/unbound-autoupdate:latest esitcparis/unbound-autoupdate:1.0.0-r0; do
      verify_image "$r" sidecar 2>/tmp/e || { echo "sidecar $r refused:"; tail -3 /tmp/e; exit 1; }
      if verify_image "$r" resolver 2>/dev/null; then echo "the resolver identity accepted sidecar image $r"; exit 1; fi
    done
    # The identity every deployed sidecar used before this change, as an
    # operator override: unchanged behaviour, both kinds accepted.
    COSIGN_IDENTITY_REGEXP="https://github.com/ESITC-Paris/unbound-distroless/.*"
    verify_image esitcparis/unbound-distroless:latest resolver 2>/dev/null \
      && verify_image esitcparis/unbound-autoupdate:latest sidecar 2>/dev/null \
      || { echo "the former identity, set explicitly, no longer verifies"; exit 1; }
    echo OK') || fail "live identity verification failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "live identity verification did not print OK: $out"
  pass "live releases (resolver latest and 1.26.1-r0, sidecar latest and 1.0.0-r0) verify under their own identity and are refused under the other"
}

t7c_config_rollback_replaces_container() {
  # On a configuration-only cycle the rollback restores the SAME image the swap
  # deployed. Without --force-recreate Compose then keeps the failed container
  # and the cycle reported "ROLLBACK performed … healthy" about a recovery that
  # never happened. Two creations of the resolver container must be seen —
  # the swap's and the rollback's — and the survivor must be the second.
  local dir="$TEST_TMPDIR/upd-t7c-$$"
  trap 'fixture_destroy "$dir"' RETURN
  hooks_image
  FIXTURE_UPDATER_IMAGE="$HOOKS_IMAGE" fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  printf '\nserver:\n  cache-min-ttl: 81\n' >> "$dir/unbound.conf"
  local p t0 t1 rc=0 out created
  p=$(fixture_project "$dir"); t0=$(date +%s)
  out=$(updater_run "$dir" _TEST_FORCE_POSTSWAP_FAIL=1 2>&1) || rc=$?
  t1=$(( $(date +%s) + 1 ))
  [ "$rc" = 1 ] || fail "T7c: a forced post-swap failure did not end the cycle in rollback (rc=$rc): $out"
  grep -q 'rollback successful' <<<"$out" || fail "T7c: the rollback did not report success: $out"
  created=$(docker events --since "$t0" --until "$t1" --filter type=container --filter event=create \
            --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound" \
            --format '{{.Actor.ID}}')
  [ "$(grep -c . <<<"$created")" -ge 2 ] || fail "T7c: the rollback did not replace the failed container (creations: $created)"
  [ "$(fixture_service_cid "$dir" unbound)" = "$(tail -1 <<<"$created")" ] \
    || fail "T7c: the surviving container is not the one the rollback created"
  pass "T7c: a configuration-only rollback really replaces the failed container"
}

t_self_update_despite_refused_resolver() {
  # A running resolver image that fails verification blocks the cycle — but a
  # FALSE refusal (identity mistake, trust-root or cosign incompatibility)
  # must not also block the sidecar update that could fix it.
  local dir="$TEST_TMPDIR/upd-selfrefused-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 v2 unsigned
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfrefused=\"1\"" "unbound-autoupdate:1")
  unsigned=$(registry_publish "FROM $MOVING_REF
LABEL test.selfrefused=\"resolver\"" "unbound-selfrefused:1")
  FIXTURE_UPDATER_IMAGE="$v1" fixture_create "$dir" "$unsigned"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local cid0; cid0=$(fixture_service_cid "$dir" unbound)
  v2=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfrefused=\"2\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"
  # The cycle is not over when it launches the helper: it still pings
  # HC_URL (/fail), records its outcome and exits — inside the very container
  # the helper replaces. A health-check endpoint that takes 8 s to answer
  # holds the cycle there, so a helper that recreates the sidecar without
  # waiting for the cycle to end kills it every time (rc 137, outcome never
  # recorded) instead of only when a slow host happens to stretch that window.
  # socat is already in the sidecar (registry_forward).
  updater_exec "$dir" /bin/sh -c \
    'printf "#!/bin/sh\nsleep 8\nprintf \"HTTP/1.0 200 OK\\r\\n\\r\\n\"\n" > /tmp/slow-hc.sh && chmod +x /tmp/slow-hc.sh
     nohup socat TCP-LISTEN:8099,fork,reuseaddr EXEC:/tmp/slow-hc.sh >/dev/null 2>&1 &'
  local _w
  for _w in $(seq 1 10); do
    updater_exec "$dir" /bin/sh -c 'netstat -ltn | grep -q ":8099 "' && break
    [ "$_w" -lt 10 ] || fail "the slow health-check endpoint never came up"
    sleep 1
  done
  local rc=0 out
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 HC_URL=http://127.0.0.1:8099 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a refused running image did not block the cycle (rc=$rc): $out"
  grep -q 'cosign verification FAILED for the RUNNING image' <<<"$out" || fail "the cycle was not blocked by the resolver's verification: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not attempted on the refused-resolver path: $out"
  [ "$(fixture_service_cid "$dir" unbound)" = "$cid0" ] || fail "the resolver was touched"
  local _i
  for _i in $(seq 1 40); do
    [ "$(service_label "$dir" updater test.selfrefused)" = 2 ] && [ -z "$(docker ps -q --filter label=unbound-autoupdate.helper=1)" ] && break
    sleep 3
  done
  [ "$(service_label "$dir" updater test.selfrefused)" = 2 ] || fail "the sidecar did not reach the new image"
  # The launching cycle's outcome survived the sidecar's replacement.
  updater_exec "$dir" grep -q '^LAST_CYCLE_STATUS=blocked$' /var/lib/unbound-autoupdate/state.env \
    || fail "the cycle that launched the helper did not record its outcome: $(updater_exec "$dir" cat /var/lib/unbound-autoupdate/state.env)"
  pass "a running resolver image refused by cosign blocks the cycle but not the sidecar's own (verified) self-update, which waits for that cycle to end"
}


t0_image_identity_unit() {
  # Pure decision logic of the digest-first design: the major-version guard
  # on real and garbage labels, the "could not verify" vs "refused" split of
  # cosign failures, the registry host of a reference (for credentials), the
  # names a rollback pin may carry, and the bound on what pulls leave behind.
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -uo pipefail
    export STATE_DIR=/tmp/st
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/verify.sh
    . /usr/local/lib/unbound-autoupdate/cache.sh
    state_init
    refuse() { major_bump "$1" "$2" || { echo "not refused: $1 -> $2"; exit 1; }; }
    allow()  { if major_bump "$1" "$2"; then echo "refused: $1 -> $2 ($MAJOR_REASON)"; exit 1; fi; }
    allow 1.26.2 1.27.0; allow 1.26.2 1.26.2-r4; allow v1.0.5 1.1.0
    refuse 1.26.2 2.0.0; refuse 1.26.2 v2.0.0; refuse 1 2; refuse 1.26.2 docs-local
    allow docs-local docs-local-2; allow docs-local 2.0.0; allow "" 2.0.0; allow 1.26.2 ""
    down() { version_downgrade "$1" "$2" || { echo "not a downgrade: $1 -> $2"; exit 1; }; }
    up()   { if version_downgrade "$1" "$2"; then echo "judged a downgrade: $1 -> $2"; exit 1; fi; }
    down 1.26.2 1.26.1; down 1.26.2 1.25.9; down 1.0.5-r4 1.0.5-r3; down 1.0.5-r4 1.0.4-r9; down v1.0.5 1.0.4
    up 1.26.1 1.26.2; up 1.26.2 1.26.2; up 1.0.5-r3 1.0.5-r4; up 1.26.2 1.26.2-r1; up 1.26.2-r4 1.26.2
    up docs-local 1.0.0; up 1.26.2 docs-local; up "" 1.0.0
    version_downgrade docs-local 1.0.0; [ -n "$DOWNGRADE_NOTE" ] || { echo "no note for an unusable label"; exit 1; }
    version_downgrade 1.26.1 1.26.2; [ -z "$DOWNGRADE_NOTE" ] || { echo "a note on an ordinary update"; exit 1; }
    # Allowed is never silent when the guard could not apply.
    major_bump docs-local docs-local-2; [[ "$MAJOR_NOTE" == *"running version label '"'"'docs-local'"'"' carries no version number"* ]] || { echo "no note for a non-numeric running label: [$MAJOR_NOTE]"; exit 1; }
    major_bump "" 2.0.0; [[ "$MAJOR_NOTE" == "one of the images carries no version label"* ]] || { echo "no note for a missing label: [$MAJOR_NOTE]"; exit 1; }
    major_bump 1.26.2 1.27.0; [ -z "$MAJOR_NOTE" ] || { echo "a note on an ordinary update: [$MAJOR_NOTE]"; exit 1; }
    cache_compatible 1.26.1 1.26.2 1 || { echo "patch bump judged cache-incompatible"; exit 1; }
    if cache_compatible 1.26.2 1.27.0 1; then echo "minor bump judged cache-compatible"; exit 1; fi
    cache_compatible "" "" 0 || { echo "config-only cycle judged cache-incompatible"; exit 1; }
    c() { [ "$(_classify_cosign_failure "$1")" = "$2" ] || { echo "classified [$1] as $(_classify_cosign_failure "$1"), expected $2"; exit 1; }; }
    c "Error: no matching signatures: none of the expected identities matched" refused
    c "Error: no signatures found" refused
    c "something nobody has seen before" refused
    c "Error: GET https://index.docker.io/v2/x/manifests/sha256-1.sig: TOOMANYREQUESTS: You have reached your unauthenticated pull rate limit" unavailable
    c "Error: no signatures found: Get \"https://registry/v2/\": dial tcp 10.0.0.1:443: i/o timeout" unavailable
    c "Error: Post https://rekor.sigstore.dev/api/v1/log: context deadline exceeded" unavailable
    # Adversarial: signer-chosen text echoed by cosign must not buy a quiet
    # "could not be checked" for a refused signature.
    c "Error: no matching signatures: none of the expected identities matched what was in the certificate, got subjects [https://github.com/x/y/.github/workflows/release.yml@refs/heads/TOOMANYREQUESTS] with issuer https://token.actions.githubusercontent.com" refused
    c "Error: no matching signatures: got subjects [https://e/x@refs/heads/a: dial tcp 1.2.3.4:443: i/o timeout] with issuer https://token.actions.githubusercontent.com" refused
    c "Error: verifying: \"GET https://r/v2/: TOOMANYREQUESTS\"" refused
    c "Error: something EOF" refused
    c "Error: annotation [ok: context deadline exceeded]" refused
    # The sidecar side words its log line like its notification.
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    . /usr/local/lib/unbound-autoupdate/selfupdate.sh
    notify() { printf "notify %s\n" "$2"; }
    msg=$(VERIFY_FAILURE=unavailable _self_report_unverified r/x@sha256:1 r/x@sha256:0 2>&1)
    grep -q "could not be checked" <<<"$msg" && ! grep -q "FAILED" <<<"$msg" || { echo "unavailable verdict worded as a failure: $msg"; exit 1; }
    msg=$(VERIFY_FAILURE=refused _self_report_unverified r/x@sha256:1 r/x@sha256:0 2>&1)
    [ "$(grep -c "FAILED" <<<"$msg")" = 2 ] || { echo "refused verdict not worded as a failure in log and notification: $msg"; exit 1; }
    [ "$(_registry_host esitcparis/unbound-distroless:1)" = "https://index.docker.io/v1/" ] \
      && [ "$(_registry_host 127.0.0.1:5000/x:1)" = 127.0.0.1:5000 ] && [ "$(_registry_host ghcr.io/o/r:1)" = ghcr.io ] \
      && [ "$(_registry_host unbound:1)" = "https://index.docker.io/v1/" ] || { echo "registry host"; exit 1; }
    [ "$(keep_name reg.example/unbound-x proj1 unbound)" != "$(keep_name reg.example/unbound-x proj2 unbound)" ] \
      || { echo "two projects share one keep name"; exit 1; }
    [[ "$(keep_name reg.example/unbound-x "p q" "s/t")" =~ ^reg.example/unbound-x:autoupdate-[A-Za-z0-9_.-]+$ ]] || { echo "keep name not a valid tag"; exit 1; }
    for r in docker.io/esitcparis/u index.docker.io/esitcparis/u esitcparis/u; do
      [ "$(familiar_repo "$r")" = esitcparis/u ] || { echo "familiar_repo $r"; exit 1; }
    done
    [ "$(familiar_repo docker.io/library/alpine)" = alpine ] || { echo "familiar_repo library"; exit 1; }
    if _valid_ref "a/b:1?x=y" || _valid_ref "a/b c" || _valid_ref "a/b%2F"; then echo "an invalid reference was accepted"; exit 1; fi
    # A quarantine recorded under another spelling of the repository still holds.
    Q=2222222222222222222222222222222222222222222222222222222222222222
    RETRY_AFTER=1h quarantine_set "docker.io/esitcparis/u@sha256:$Q"
    RETRY_AFTER=1h quarantine_active "esitcparis/u@sha256:$Q" || { echo "quarantine missed across repository spellings"; exit 1; }
    quarantine_clear
    write_pin_file /tmp/p.yml "$(keep_name reg.example/unbound-x proj unbound)" unbound || { echo "the keep name was refused as a pin"; exit 1; }
    if write_pin_file /tmp/p.yml "reg.example/unbound-x:latest" unbound 2>/dev/null; then echo "a mutable tag was accepted as a pin"; exit 1; fi
    # prune_pulled against a stub image store: ref -> "id|tags".
    D=1111111111111111111111111111111111111111111111111111111111111111
    A="r/x@sha256:${D/1/a}"; B="r/x@sha256:${D/1/b}"; C="r/x@sha256:${D/1/c}"; K="r/x@sha256:$D"
    declare -A STORE=( [$A]="sha256:ia|$A" [$B]="sha256:ib|r/x:1 $B" [$C]="sha256:ic|$C" [$K]="sha256:ik|$K" )
    : > /tmp/removed
    docker() {
      case "$1 $2" in
        "image inspect")
          local e="${STORE[$3]:-}"; [ -n "$e" ] || return 1
          case "$5" in *RepoTags*) printf "%s\n" ${e#*|} ;; *) printf "%s\n" "${e%%|*}" ;; esac ;;
        "image rm") echo "$3" >> /tmp/removed; unset "STORE[$3]" ;;
      esac
    }
    state_set PULLED_REFS "$A $B $C $K r/x@sha256:${D/1/d}"
    PRUNE_PROTECT_IDS="sha256:ic" prune_pulled "$K"
    # Removed: only A (untagged, unprotected). Kept: B (a TAG names its image —
    # on containerd, removing its digest would untag r/x:1), C (protected), K
    # (asked to keep). Forgotten: the one with no local record.
    [ "$(cat /tmp/removed)" = "$A" ] || { echo "prune removed: $(cat /tmp/removed)"; exit 1; }
    [ "$(state_get PULLED_REFS)" = "$B $C $K" ] || { echo "prune kept: $(state_get PULLED_REFS)"; exit 1; }
    echo OK') || fail "image identity unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "image identity unit did not print OK: $out"
  pass "major guard (numeric and garbage labels), could-not-verify vs refused, registry host, pin names, pulled-image bound"
}

t_cycles_after_rollback() {
  # After a rollback the operator's tag must name the rolled-back image again,
  # and every later cycle must keep working — the quarantine skip, a check
  # run, and a NEWER release arriving. All images exist locally only under
  # the declared tag, as on a production host. After every exit, a plain
  # `docker compose up -d` must recreate nothing.
  local dir="$TEST_TMPDIR/upd-afterrb-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  hooks_image
  registry_up
  FIXTURE_UPDATER_IMAGE="$HOOKS_IMAGE" signed_resolver_fixture "$dir" "unbound-afterrb:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) rc out r
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"

  r=$(registry_publish "FROM $MOVING_REF
LABEL test.afterrb=\"2\"" "unbound-afterrb:1"); registry_sign "$dir" "$r"
  rc=0; out=$(updater_run "$dir" "${keys[@]}" _TEST_FORCE_POSTSWAP_FAIL=1 2>&1) || rc=$?
  [ "$rc" = 1 ] && grep -q 'rollback successful' <<<"$out" || fail "cycle 1: no successful rollback (rc=$rc): $out"
  [ -z "$(service_label "$dir" unbound test.afterrb)" ] || fail "cycle 1: production is not back on the previous image"
  compose_up_is_noop "$dir" || fail "after a rollback, a plain 'docker compose up -d' recreated containers"

  rc=0; out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 2 ] && grep -q 'is quarantined' <<<"$out" || fail "cycle 2 after the rollback did not reach the quarantine (rc=$rc): $out"
  compose_up_is_noop "$dir" || fail "after a quarantine skip, a plain 'docker compose up -d' recreated containers"

  r=$(registry_publish "FROM $MOVING_REF
LABEL test.afterrb=\"3\"" "unbound-afterrb:1"); registry_sign "$dir" "$r"
  out=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" \
        exec -T -e COSIGN_PUBLIC_KEY="$TEST_PUBKEY" -e COSIGN_IGNORE_TLOG=1 updater /usr/local/bin/entrypoint.sh check 2>&1) \
    || fail "check mode on a newer release failed: $out"
  [ -z "$(service_label "$dir" unbound test.afterrb)" ] || fail "check mode deployed"
  compose_up_is_noop "$dir" || fail "after check mode, a plain 'docker compose up -d' recreated containers"

  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "cycle 3 with a newer release failed: $out"
  [ "$(service_label "$dir" unbound test.afterrb)" = 3 ] || fail "cycle 3: the newer release was not deployed"
  compose_up_is_noop "$dir" || fail "after an update, a plain 'docker compose up -d' recreated containers"
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "idle cycle after the update failed: $out"
  local_names_intact "$SIGNED_RESOLVER" || fail "after an idle cycle following an update, a local name is gone"
  compose_up_is_noop "$dir" || fail "after an idle cycle following an update, 'up -d' recreated containers"
  pass "after a rollback: quarantine skip, check run and a newer release all work; 'up -d' is a no-op after each"
}

t_major_guard_tag_only() {
  # The version of what runs comes from the running CONTAINER: here the
  # operator's own `docker compose pull` has moved the tag to a 2.x release
  # and the keep name is gone too, so on the containerd store the running
  # image has no record left at all. The guard must still see 1.x -> 2.x.
  # A preflight refusal on the way must leave `up -d` a no-op.
  local dir="$TEST_TMPDIR/upd-majtag-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  signed_resolver_fixture "$dir" "unbound-majtag:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) rc out r
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"

  cp "$dir/unbound.conf" "$dir/unbound.conf.good"
  printf 'server:\n  this-is-not-a-directive: 1\n' >> "$dir/unbound.conf"
  rc=0; out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 1 ] && grep -q 'preflight' <<<"$out" || fail "an invalid configuration was not refused in preflight (rc=$rc): $out"
  compose_up_is_noop "$dir" || fail "after a preflight refusal, a plain 'docker compose up -d' recreated containers"
  mv "$dir/unbound.conf.good" "$dir/unbound.conf"

  r=$(registry_publish "FROM $MOVING_REF
LABEL org.opencontainers.image.version=\"2.0.0\"" "unbound-majtag:1"); registry_sign "$dir" "$r"
  keep_names_of "$REGISTRY_HOST/unbound-majtag" | xargs -r docker image rm >/dev/null 2>&1 || true
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" pull -q unbound ) >/dev/null 2>&1 || fail "setup: operator pull failed"
  rc=0; out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 2 ] && grep -q 'major version bump' <<<"$out" || fail "the major-version guard did not fire on a tag-only image (rc=$rc): $out"
  [ "$(service_label "$dir" unbound org.opencontainers.image.version)" != 2.0.0 ] || fail "a major bump was deployed"
  pass "major-version guard holds when the running image has no local record; a preflight refusal leaves 'up -d' a no-op"
}

t_rollback_without_registry() {
  # The registry goes away while the cycle runs (stopped as soon as the
  # canary starts): the rollback must not need it.
  local dir="$TEST_TMPDIR/upd-rbnoreg-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  hooks_image
  registry_up
  FIXTURE_UPDATER_IMAGE="$HOOKS_IMAGE" signed_resolver_fixture "$dir" "unbound-rbnoreg:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) r
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"
  r=$(registry_publish "FROM $MOVING_REF
LABEL test.rbnoreg=\"2\"" "unbound-rbnoreg:1"); registry_sign "$dir" "$r"

  local log="$TEST_TMPDIR/upd-rbnoreg-$$.log" ev="$TEST_TMPDIR/upd-rbnoreg-ev-$$" rc=0 bg evp _i stopped=0
  : > "$ev"
  docker events --filter type=container --filter event=start \
    --filter "name=unbound-canary-$(fixture_project "$dir")" --format '{{.Actor.ID}}' > "$ev" & evp=$!
  ( updater_run "$dir" "${keys[@]}" _TEST_FORCE_POSTSWAP_FAIL=1 >"$log" 2>&1 ) & bg=$!
  for _i in $(seq 1 2400); do
    if [ -s "$ev" ]; then docker stop "$REGISTRY_NAME" >/dev/null && stopped=1; break; fi
    kill -0 "$bg" 2>/dev/null || break
    sleep 0.05
  done
  wait "$bg" || rc=$?
  kill "$evp" 2>/dev/null || true; wait "$evp" 2>/dev/null || true
  local out; out=$(cat "$log"); rm -f "$log" "$ev"
  [ "$stopped" = 1 ] || fail "setup: the registry was not stopped during the cycle: $out"
  [ "$rc" = 1 ] && grep -q 'rollback successful' <<<"$out" || fail "the rollback failed without the registry (rc=$rc): $out"
  [ -z "$(service_label "$dir" unbound test.rbnoreg)" ] || fail "production is not back on the previous image"
  pass "a rollback needs no registry"
}

t_interrupted_swap_recovery() {
  # (1) The cycle is killed after `compose up` created the new resolver and
  # before the post-swap gate passed: the next cycle must JUDGE that image,
  # not report "up to date" on something never validated. (2) A swap killed
  # inside `compose up` leaves the resolver stopped: the next cycle must
  # bring DNS back (roll back), not wait for a container nobody will start.
  local dir="$TEST_TMPDIR/upd-intr-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  signed_resolver_fixture "$dir" "unbound-intr:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) r p
  p=$(fixture_project "$dir")
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"
  r=$(registry_publish "FROM $MOVING_REF
LABEL test.intr=\"2\"" "unbound-intr:1"); registry_sign "$dir" "$r"

  local log="$TEST_TMPDIR/upd-intr-$$.log" ev="$TEST_TMPDIR/upd-intr-ev-$$" bg evp _i killed=0
  : > "$ev"
  docker events --filter type=container --filter event=start --filter "label=com.docker.compose.project=$p" \
    --filter "label=com.docker.compose.service=unbound" --format '{{.Actor.ID}}' > "$ev" & evp=$!
  ( updater_run "$dir" "${keys[@]}" >"$log" 2>&1 ) & bg=$!
  for _i in $(seq 1 4000); do
    if [ -s "$ev" ]; then
      updater_exec "$dir" pkill -KILL -f /usr/local/bin/unbound-autoupdate && killed=1
      break
    fi
    kill -0 "$bg" 2>/dev/null || break
    sleep 0.02
  done
  wait "$bg" 2>/dev/null || true
  kill "$evp" 2>/dev/null || true; wait "$evp" 2>/dev/null || true
  local out; out=$(cat "$log"); rm -f "$log" "$ev"
  [ "$killed" = 1 ] || fail "setup: the cycle was not killed during the swap: $out"
  grep -q 'production updated and verified' <<<"$out" && fail "setup: the cycle finished before it was killed: $out"
  updater_exec "$dir" grep -q '^SWAP_INTENT=.' /var/lib/unbound-autoupdate/state.env || fail "no swap intent was persisted"
  local rc=0
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 0 ] && grep -q 'interrupted during the swap' <<<"$out" && grep -q 'production updated and verified' <<<"$out" \
    || fail "the interrupted swap was not finished by judging the new image (rc=$rc): $out"
  [ "$(service_label "$dir" unbound test.intr)" = 2 ] || fail "the validated new image is not what runs"

  # (2) As left by a kill inside `compose up`: an intent, a stopped resolver.
  local running_id; running_id=$(docker inspect "$(fixture_service_cid "$dir" unbound)" --format '{{.Image}}')
  updater_exec "$dir" /bin/bash -c ". /usr/local/lib/unbound-autoupdate/log.sh; . /usr/local/lib/unbound-autoupdate/state.sh;
    state_set SWAP_INTENT \"$r sha256:$(printf '0%.0s' $(seq 64)) $running_id x 1 0 $REGISTRY_HOST/unbound-intr\""
  docker compose -p "$p" --project-directory "$dir" -f "$dir/docker-compose.yml" stop unbound >/dev/null 2>&1
  local t0; t0=$(date +%s); rc=0
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 1 ] && grep -q 'rollback successful' <<<"$out" || fail "a stopped resolver after an interrupted swap was not recovered (rc=$rc): $out"
  [ $(( $(date +%s) - t0 )) -lt 60 ] || fail "recovery waited for discovery's timeout instead of acting"
  [ "$(service_label "$dir" unbound test.intr)" = 2 ] || fail "the recovered resolver is not the image that was running"
  updater_exec "$dir" dig +time=3 +tries=2 @unbound example.com A | grep -q 'status: NOERROR' || fail "DNS is not back after the recovery"
  updater_exec "$dir" grep -q '^SWAP_INTENT=$' /var/lib/unbound-autoupdate/state.env || fail "the swap intent was not cleared"
  pass "an interrupted swap is finished by the next cycle: the new image judged, or DNS restored from a stopped resolver"
}

t_self_update_after_tag_moved() {
  # The operator pulled the sidecar's tag (and the keep name is gone): on the
  # containerd store the running sidecar image then has no record and no
  # repository digest. Self-update used to log "locally built — skipped" at
  # info level and stay off forever, silently.
  local dir="$TEST_TMPDIR/upd-selfmoved-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 v2
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfmoved=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" signed_resolver_fixture "$dir" "unbound-selfmoved:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) out
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"
  v2=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfmoved=\"2\"" "unbound-autoupdate:1"); registry_sign "$dir" "$v2"
  keep_names_of "$REGISTRY_HOST/unbound-autoupdate" | xargs -r docker image rm >/dev/null 2>&1 || true
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" pull -q updater metrics ) >/dev/null 2>&1 || fail "setup: operator pull failed"
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "cycle failed: $out"
  grep -q 'locally built' <<<"$out" && fail "self-update switched itself off: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not attempted: $out"
  local _i
  for _i in $(seq 1 40); do
    [ "$(service_label "$dir" updater test.selfmoved)" = 2 ] && [ -z "$(docker ps -q --filter label=unbound-autoupdate.helper=1)" ] && break
    sleep 3
  done
  [ "$(service_label "$dir" updater test.selfmoved)" = 2 ] || fail "the sidecar did not reach the new image"
  pass "self-update still works when the running sidecar image lost its tag and record"
}

t_idle_cycles_keep_local_names() {
  # Several ordinary, up-to-date cycles in a row — the commonest thing the
  # sidecar does — with the resolver AND the sidecar from a registry, held
  # locally only under the operator's tags. After each one the operator's
  # tags and the keep names must still exist (an image rm of a pulled digest
  # untagged them all on the containerd store) and `up -d` must be a no-op.
  local dir="$TEST_TMPDIR/upd-idle-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1; v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.idle=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" signed_resolver_fixture "$dir" "unbound-idle:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) out n
  for n in 1 2 3; do
    out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "idle cycle $n failed: $out"
    local_names_intact "$v1" "$SIGNED_RESOLVER" || fail "after idle cycle $n a local name is gone: $(docker images --format '{{.Repository}}:{{.Tag}}' | grep "$REGISTRY_HOST")"
    compose_up_is_noop "$dir" || fail "after idle cycle $n, a plain 'docker compose up -d' recreated containers"
  done
  pass "three idle cycles: the operator's tags and the keep names survive for resolver and sidecar; 'up -d' stays a no-op"
}

t_prune_keeps_tagged_images() {
  # prune_pulled against a REAL image store. `docker image rm <repo>@<digest>`
  # removes every name of that image in the repository on the containerd
  # store (only the digest reference on the classic one), so a pulled digest
  # whose image an operator's tag or a keep name also names must never be
  # removed — whether or not a container happens to use it at that moment.
  local tag
  registry_up
  trap 'registry_down' RETURN
  tag=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.prune=\"1\"" "unbound-prune:1")
  docker pull -q "$tag" >/dev/null
  local d; d=$(registry_digest "$tag")
  docker tag "$tag" "${tag%:*}:autoupdate-prune-unbound"
  local out
  out=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock --entrypoint /bin/bash "$UPDATER_IMAGE" -c "
    set -uo pipefail
    export STATE_DIR=/tmp/st
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    state_init
    state_set PULLED_REFS '$d'
    prune_pulled 'other@sha256:$(printf '0%.0s' $(seq 64))'
    echo OK" 2>&1) || fail "prune run failed: $out"
  docker image inspect "$tag" >/dev/null 2>&1 || fail "prune_pulled removed the operator's tag $tag"
  docker image inspect "${tag%:*}:autoupdate-prune-unbound" >/dev/null 2>&1 || fail "prune_pulled removed the keep name"
  docker image rm "$tag" "${tag%:*}:autoupdate-prune-unbound" >/dev/null 2>&1 || true
  pass "prune_pulled never removes a pulled digest whose image a tag still names"
}

t_swap_killed_mid_recreate() {
  # The real state a swap leaves when `docker compose up` itself is killed
  # mid-recreate (Compose v5: new container created under a temporary name,
  # old one being stopped): old Exited, new Created, no restart policy starts
  # either, DNS down. The resolver ignores its stop signal here, so the stop
  # phase lasts its whole grace period and the kill lands inside it.
  local dir="$TEST_TMPDIR/upd-midrc-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  FIXTURE_UNBOUND_EXTRA='    stop_signal: SIGWINCH
    stop_grace_period: 30s' signed_resolver_fixture "$dir" "unbound-midrc:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) r p
  p=$(fixture_project "$dir")
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"
  r=$(registry_publish "FROM $MOVING_REF
LABEL test.midrc=\"2\"" "unbound-midrc:1"); registry_sign "$dir" "$r"

  local ev="$TEST_TMPDIR/upd-midrc-ev-$$" bg evp _i killed=0
  : > "$ev"
  docker events --filter type=container --filter event=kill --filter "label=com.docker.compose.project=$p" \
    --filter "label=com.docker.compose.service=unbound" --format '{{.Actor.ID}}' > "$ev" & evp=$!
  ( updater_run "$dir" "${keys[@]}" >/dev/null 2>&1 ) & bg=$!
  for _i in $(seq 1 4000); do
    if [ -s "$ev" ]; then
      sleep 2
      updater_exec "$dir" sh -c 'pkill -KILL -f unbound-autoupdate; pkill -KILL -f "docker compose"; pkill -KILL -f docker-compose' >/dev/null 2>&1 || true
      killed=1; break
    fi
    kill -0 "$bg" 2>/dev/null || break
    sleep 0.05
  done
  wait "$bg" 2>/dev/null || true
  kill "$evp" 2>/dev/null || true; wait "$evp" 2>/dev/null || true
  rm -f "$ev"
  [ "$killed" = 1 ] || fail "setup: the swap never reached the stop phase"
  # Let the daemon finish the stop it was asked for: the old container exits.
  for _i in $(seq 1 40); do
    [ -z "$(docker ps -q --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound")" ] && break
    sleep 1
  done
  [ -z "$(docker ps -q --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound")" ] \
    || fail "setup: a resolver is still running — the kill did not land mid-recreate"
  local left; left=$(docker ps -aq --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound" | wc -l | tr -d ' ')
  # Depending on where in the recreate the kill landed, Compose leaves one
  # container or two (old Exited + new Created under a temporary name). The
  # two-container shape is the one that broke discovery; when the kill left
  # one, the second is added exactly as Compose creates it (same project and
  # service labels, not started), so both shapes are always exercised.
  if [ "$left" -lt 2 ]; then
    local src lbl=()
    src=$(docker ps -aq --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound" | head -1)
    while IFS= read -r l; do [ -n "$l" ] && lbl+=(--label "$l"); done \
      < <(docker inspect "$src" --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}')
    docker create --name "upd-midrc-tmp-$$_unbound" --volumes-from "$src" "${lbl[@]}" "$(docker inspect "$src" --format '{{.Image}}')" >/dev/null \
      || fail "setup: could not add the second leftover container"
    left=$(( left + 1 ))
  fi

  local rc=0 out
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  grep -q 'candidate services' <<<"$out" && fail "discovery died on the leftover containers: $out"
  [ "$(docker ps -q --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound" | wc -l | tr -d ' ')" = 1 ] \
    || fail "after recovery the resolver is not running exactly once (rc=$rc): $out"
  [ "$(docker ps -aq --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.service=unbound" | wc -l | tr -d ' ')" = 1 ] \
    || fail "after recovery leftover resolver containers remain"
  updater_exec "$dir" dig +time=3 +tries=3 @unbound example.com A | grep -q 'status: NOERROR' || fail "DNS is not back after recovery: $out"
  updater_exec "$dir" grep -q '^SWAP_INTENT=$' /var/lib/unbound-autoupdate/state.env || fail "the swap intent was not resolved: $out"
  pass "a swap killed inside 'compose up' ($left resolver containers left, none running) is recovered: one running resolver, DNS back, intent resolved"
}

t_stale_intents_resolve() {
  # Swap intents the next cycle finds contradicted or obsolete must resolve
  # themselves without touching production: (1) someone deployed by hand
  # while the sidecar was down — the resolver runs neither image of the
  # intent; (2) a configuration-only swap killed before `compose up` ran —
  # the very container recorded before the swap still runs. Real containers,
  # real state; no rollback, no "updated" for something that never happened.
  local dir="$TEST_TMPDIR/upd-stale-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local cid0 id0 z out rc
  cid0=$(fixture_service_cid "$dir" unbound)
  id0=$(docker inspect "$cid0" --format '{{.Image}}')
  z="sha256:$(printf '0%.0s' $(seq 64))"
  setintent() { updater_exec "$dir" /bin/bash -c ". /usr/local/lib/unbound-autoupdate/log.sh; . /usr/local/lib/unbound-autoupdate/state.sh; state_set SWAP_INTENT \"$1\""; }

  setintent "esitcparis/unbound-distroless@$z $z ${z/0/1} x 1 0 esitcparis/unbound-distroless deadbeef -"
  rc=0; out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" = 0 ] && grep -q 'contradicted by what runs' <<<"$out" || fail "a contradicted intent was not dropped (rc=$rc): $out"
  grep -qi 'rolling back' <<<"$out" && fail "a contradicted intent rolled production back: $out"
  [ "$(fixture_service_cid "$dir" unbound)" = "$cid0" ] || fail "a contradicted intent touched the resolver"

  printf '\nserver:\n  cache-min-ttl: 83\n' >> "$dir/unbound.conf"
  setintent "esitcparis/unbound-distroless@$z $id0 $id0 x 0 1 esitcparis/unbound-distroless $cid0 -"
  rc=0; out=$(updater_run "$dir" 2>&1) || rc=$?
  grep -q 'completed after an interrupted cycle' <<<"$out" && fail "an untouched configuration swap was recorded as completed: $out"
  grep -q 'interrupted before production changed' <<<"$out" || fail "the obsolete intent was not recognised: $out"
  [ "$rc" = 0 ] && [ "$(fixture_service_cid "$dir" unbound)" != "$cid0" ] || fail "the configuration change was not then deployed normally (rc=$rc): $out"
  pass "contradicted and obsolete swap intents resolve themselves; nothing is rolled back or falsely recorded"
}

t_idle_cycle_registry_traffic() {
  # An idle cycle asks the registry about two references (resolver and
  # sidecar) and must do so with HEAD requests only: Docker Hub counts a
  # manifest GET as a pull, and anything pulled every hour from every host
  # behind one NAT runs into the anonymous limit. Counted from the
  # registry's own access log.
  local dir="$TEST_TMPDIR/upd-traffic-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1; v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.traffic=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" signed_resolver_fixture "$dir" "unbound-traffic:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) out t0 log heads gets blobs
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"
  # Delimited by line count, not by time: the daemon's clock (a VM's, under
  # Docker Desktop or dind) need not agree with this host's to the second.
  sleep 2; t0=$(docker logs "$REGISTRY_NAME" 2>&1 | wc -l)
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "idle cycle failed: $out"
  sleep 1
  log=$(docker logs "$REGISTRY_NAME" 2>&1 | tail -n +"$((t0 + 1))" | grep 'response completed' || true)
  heads=$(grep -c 'http.request.method=HEAD.*manifests' <<<"$log" || true)
  gets=$(grep -c 'http.request.method=GET.*manifests' <<<"$log" || true)
  blobs=$(grep -c 'http.request.method=GET.*blobs' <<<"$log" || true)
  [ "$gets" = 0 ] && [ "$blobs" = 0 ] || fail "an idle cycle fetched from the registry: $gets manifest GETs, $blobs blob GETs:
$(grep -oE 'http.request.method=[A-Z]+|http.request.uri="[^"]*"|http.request.useragent="[^"]*"' <<<"$log" | paste - - - )
cycle output: $out"
  [ "$heads" -le 2 ] || fail "an idle cycle made $heads manifest HEAD requests (expected at most 2):
$(grep -oE 'http.request.method=[A-Z]+|http.request.uri="[^"]*"|http.request.useragent="[^"]*"' <<<"$log" | paste - - - )"
  # Where a direct HEAD cannot work from the sidecar (custom CA, mirror-only
  # network…), the daemon is asked instead: that path must give the same
  # answer. Forced here by disabling the HEAD path.
  local via_daemon
  via_daemon=$(updater_exec "$dir" /bin/bash -c "
    . /usr/local/lib/unbound-autoupdate/log.sh; . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    _head_digest() { return 1; }
    resolve_registry_digest '$SIGNED_RESOLVER'" 2>&1) || fail "the daemon fallback failed: $via_daemon"
  [ "$via_daemon" = "$(registry_digest "$SIGNED_RESOLVER")" ] \
    || fail "the daemon fallback resolved '$via_daemon', the registry serves '$(registry_digest "$SIGNED_RESOLVER")'"
  pass "an idle cycle costs the registry $heads manifest HEAD requests and no GET; the daemon fallback resolves the same digest"
}

t_downgrade_refused() {
  # Whoever can move the tag can point it at an OLDER, properly signed
  # release: it verifies and it passes the canary. Refused by default (exit
  # 2, production untouched, the operator's tag unmoved); ALLOW_DOWNGRADE=1
  # lets it through.
  local dir="$TEST_TMPDIR/upd-down-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  signed_resolver_fixture "$dir" "unbound-down:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1) rc out r cid0
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"
  cid0=$(fixture_service_cid "$dir" unbound)
  r=$(registry_publish "FROM $MOVING_REF
LABEL org.opencontainers.image.version=\"1.26.1\"" "unbound-down:1"); registry_sign "$dir" "$r"
  rc=0; out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 2 ] && grep -q 'downgrade 1.26.2 -> 1.26.1 refused' <<<"$out" || fail "a signed older release was not refused (rc=$rc): $out"
  [ "$(fixture_service_cid "$dir" unbound)" = "$cid0" ] || fail "the downgrade touched production"
  compose_up_is_noop "$dir" || fail "after a refused downgrade, 'up -d' recreated containers"
  rc=0; out=$(updater_run "$dir" "${keys[@]}" ALLOW_DOWNGRADE=1 2>&1) || rc=$?
  [ "$rc" = 0 ] && [ "$(service_label "$dir" unbound org.opencontainers.image.version)" = 1.26.1 ] \
    || fail "ALLOW_DOWNGRADE=1 did not let the older release through (rc=$rc): $out"
  pass "a signed older release is refused unless ALLOW_DOWNGRADE=1"
}

t_baseline_image_verified() {
  # The image a sidecar finds ALREADY running when it first starts was never
  # verified: only a digest that differed from the running one was. A
  # configuration-only change then canaried and recreated that image without
  # this sidecar ever having checked it. Every image about to be canaried or
  # recreated must be verified — the running one once, at baseline — and a
  # failure must leave the resolver SERVING: what is running already ran.
  local dir="$TEST_TMPDIR/upd-baseline-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local unsigned
  unsigned=$(registry_publish "FROM $MOVING_REF
LABEL test.baseline=\"unsigned\"" "unbound-baseline:1")
  fixture_create "$dir" "$unsigned"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local cid0; cid0=$(fixture_service_cid "$dir" unbound)
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1)

  local rc=0 out
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "baseline: an unverifiable running image passed the first cycle (rc=$rc): $out"
  grep -q 'cosign verification FAILED for the RUNNING image' <<<"$out" \
    || fail "baseline: the cycle failed, but not at the verification of the running image: $out"
  grep -qiE 'no signatures found|no matching signatures' <<<"$out" \
    || fail "baseline: the refusal is not cosign's verdict on the signature: $out"
  [ "$(fixture_service_cid "$dir" unbound)" = "$cid0" ] || fail "baseline: the resolver was touched by a failed verification"
  updater_exec "$dir" dig +time=3 +tries=2 @unbound example.com A | grep -q 'status: NOERROR' \
    || fail "baseline: the resolver stopped serving after a failed verification"

  # A configuration change must not canary or recreate it either.
  printf '\nserver:\n  cache-min-ttl: 77\n' >> "$dir/unbound.conf"
  rc=0; out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "config-only cycle on an unverifiable image did not fail (rc=$rc): $out"
  grep -q 'preflight' <<<"$out" && fail "config-only cycle ran the preflight on an image it could not verify: $out"
  [ "$(fixture_service_cid "$dir" unbound)" = "$cid0" ] || fail "config-only cycle recreated an unverifiable image"

  # Once signed, the same configuration change goes through, and the verdict
  # is remembered: the next unchanged cycle does not ask cosign again.
  registry_sign "$dir" "$unsigned"
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "cycle after signing failed: $out"
  grep -q 'cosign signature verified for' <<<"$out" || fail "the newly signed image was not verified: $out"
  [ "$(fixture_service_cid "$dir" unbound)" != "$cid0" ] || fail "the configuration change was not deployed once the image verified"
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "unchanged cycle failed: $out"
  grep -q 'cosign signature verified for' <<<"$out" && fail "an unchanged, already verified digest was verified again: $out"
  updater_exec "$dir" grep -q '^VERIFIED_DIGEST=.*@sha256:' /var/lib/unbound-autoupdate/state.env \
    || fail "VERIFIED_DIGEST not recorded"
  pass "the running image is verified at baseline; a failure keeps it serving but blocks any canary or recreation; the verdict is remembered per digest"
}

t_swap_pins_verified_digest() {
  # Between the pull/verify/canary of a digest and the `compose up` that
  # deploys it, the TAG can move — a concurrent pull, or `pull_policy:
  # always` pulling again inside `compose up` itself. Deploying by tag then
  # puts into production a digest that was never verified nor canaried. The
  # tag is moved here, deterministically, while the canary is running.
  local dir="$TEST_TMPDIR/upd-pin-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  FIXTURE_UNBOUND_EXTRA='    pull_policy: always' signed_resolver_fixture "$dir" "unbound-pin:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1)
  updater_run "$dir" "${keys[@]}" >/dev/null || fail "baseline cycle failed"

  local verified rogue
  verified=$(registry_publish "FROM $MOVING_REF
LABEL test.pin=\"verified\"" "unbound-pin:1")
  registry_sign "$dir" "$verified"
  # The rogue image is built under another name now and pushed under the tag
  # only once the canary is up.
  rogue="$REGISTRY_HOST/unbound-pin-rogue:1"
  printf '%s\n' "$rogue" >> "$_TRACK_FILE"
  printf 'FROM %s\nLABEL test.pin="rogue"\n' "$MOVING_REF" | docker build -q -t "$rogue" - >/dev/null

  # The canary can live for well under a second, so its start is caught from
  # the daemon's event stream rather than by polling, and the LOCAL tag is
  # moved first (instant: what a concurrent pull would do), then pushed (what
  # `pull_policy: always` would fetch).
  local log="$TEST_TMPDIR/upd-pin-$$.log" ev="$TEST_TMPDIR/upd-pin-ev-$$" rc=0 bg evp _i moved=0
  : > "$ev"
  docker events --filter type=container --filter event=start \
    --filter "name=unbound-canary-$(fixture_project "$dir")" --format '{{.Actor.ID}}' > "$ev" & evp=$!
  ( updater_run "$dir" "${keys[@]}" >"$log" 2>&1 ) & bg=$!
  for _i in $(seq 1 2400); do
    if [ -s "$ev" ]; then
      docker tag "$rogue" "$verified" && moved=1
      docker push -q "$verified" >/dev/null || moved=0
      break
    fi
    kill -0 "$bg" 2>/dev/null || break
    sleep 0.05
  done
  wait "$bg" || rc=$?
  kill "$evp" 2>/dev/null || true; wait "$evp" 2>/dev/null || true
  local out; out=$(cat "$log"); rm -f "$log" "$ev"
  [ "$moved" = 1 ] || fail "test setup: the canary was never seen, the tag was not moved: $out"
  [ "$rc" = 0 ] || fail "the swap did not deploy the verified digest (rc=$rc): $out"
  [ "$(service_label "$dir" unbound test.pin)" = verified ] \
    || fail "production runs the '$(service_label "$dir" unbound test.pin)' image, not the verified and canaried one"
  docker image rm "$verified" >/dev/null 2>&1 || true
  pass "the swap deploys the verified, canaried digest even when the tag moves during the cycle under pull_policy: always"
}

t_self_update_trust() {
  # (1) A sidecar image refused by cosign must never be executed by the
  # sidecar: the refused pull used to leave the sidecar's TAG on it, and the
  # canary cloned production state with `docker run <that tag>`. (2) A digest
  # pin an operator puts on the sidecar's own services must be honoured: the
  # sidecar read only the RESOLVER's compose files and self-updated straight
  # past such a pin.
  local dir="$TEST_TMPDIR/upd-selftrust-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 tag
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selftrust=\"1\"" "unbound-autoupdate:1")
  tag="$v1"
  FIXTURE_UPDATER_IMAGE="$v1" signed_resolver_fixture "$dir" "unbound-selftrust:1"
  local keys=(COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1)
  local id1 d1; id1=$(fixture_service_image_id "$dir" updater); d1=$(registry_digest "$v1")
  [ -n "$id1" ] && [ -n "$d1" ] || fail "setup: no sidecar image id or digest"

  # An UNSIGNED v2 under the sidecar's tag in the registry. Locally the tag
  # still names v1, exactly as on a production host before an update.
  local v2; v2=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selftrust=\"2-unsigned\"" "unbound-autoupdate:1")
  local d2; d2=$(registry_digest "$v2")
  [ "$(docker image inspect "$tag" --format '{{.Id}}')" = "$id1" ] || fail "setup: the local tag does not name v1"

  local rc=0 out
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "an unsigned sidecar image did not fail the cycle (rc=$rc): $out"
  grep -q 'self-update: cosign verification FAILED' <<<"$out" || fail "the refusal was not the sidecar's cosign gate: $out"
  [ "$(docker image inspect "$tag" --format '{{.Id}}' 2>/dev/null)" = "$id1" ] \
    || fail "the local sidecar tag was moved onto the refused image ($(docker image inspect "$tag" --format '{{.Id}}' 2>/dev/null)) — 'docker compose run … check' would run it"
  compose_up_is_noop "$dir" || fail "after a refused sidecar image, a plain 'docker compose up -d' recreated containers"

  # The canary's state clone: by an immutable reference, never by the tag.
  printf '\nserver:\n  cache-min-ttl: 78\n' >> "$dir/unbound.conf"
  local t0 t1 created
  t0=$(date +%s)
  out=$(updater_run "$dir" "${keys[@]}" SELF_UPDATE=0 2>&1) || fail "config-change cycle failed: $out"
  t1=$(( $(date +%s) + 1 ))
  created=$(docker events --since "$t0" --until "$t1" --filter type=container --filter event=create \
            --format '{{.Actor.Attributes.image}}')
  grep -qxF "$tag" <<<"$created" && fail "a container was created from the sidecar's TAG: $created"
  grep -qxE "$id1|$d1" <<<"$created" || fail "no container was created from the sidecar's own immutable image (the state clone): $created"

  # (2) Sign v2 — now it WOULD be applied — and pin the sidecar's services on
  # v1 by digest with an override in the project directory, as the runbook
  # tells an operator to. The pin must win.
  registry_sign "$dir" "$d2"
  printf 'services:\n  updater:\n    image: %s\n  metrics:\n    image: %s\n' "$d1" "$d1" > "$dir/pin.yml"
  operator_compose "$dir" -f "$dir/docker-compose.yml" -f "$dir/pin.yml" up -d --no-deps updater metrics >/dev/null 2>&1 \
    || fail "setup: could not pin the sidecar services"
  registry_forward "$dir"
  local cid_pinned; cid_pinned=$(fixture_service_cid "$dir" updater)
  out=$(updater_run "$dir" "${keys[@]}" 2>&1) || fail "cycle with a pinned sidecar failed: $out"
  grep -q 'launching the apply helper' <<<"$out" && fail "self-update ignored the operator's digest pin on the sidecar: $out"
  sleep 2
  [ "$(fixture_service_cid "$dir" updater)" = "$cid_pinned" ] || fail "the pinned sidecar was recreated"
  pass "a refused sidecar image is never run (the tag never moves to it, state clone by image id), and a digest pin on the sidecar's own services stops self-update"
}

t_host_mode_cycle_refused_early() {
  # A host-networked sidecar cannot run a canary, so a cycle with something to
  # deploy must stop before cosign, the preflight containers or anything
  # else — while an up-to-date cycle, which needs no canary, keeps working.
  local dir="$TEST_TMPDIR/upd-hostcycle-$$"
  trap 'fixture_destroy "$dir"' RETURN
  FIXTURE_UPDATER_EXTRA='    network_mode: host' \
    fixture_create "$dir" "$MOVING_REF"
  local out rc=0
  out=$(updater_run "$dir" 2>&1) || fail "host mode: the up-to-date cycle failed: $out"
  printf '\nserver:\n  cache-min-ttl: 79\n' >> "$dir/unbound.conf"
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "host mode: a cycle with a change did not fail (rc=$rc): $out"
  grep -q 'network_mode: host' <<<"$out" || fail "host mode: the refusal does not name network_mode: host: $out"
  grep -q 'preflight' <<<"$out" && fail "host mode: the preflight ran before the refusal: $out"
  pass "host-networked sidecar: up-to-date cycles work; a cycle with a change is refused before verification or preflight"
}

ALL_TESTS="
  t0_image_sane
  t0_state_unit
  t0_logfmt_unit
  t0_compose_file_args_unit
  t0_notify_host_unit
  t0_config_fingerprint_directory_unit
  t0_config_fingerprint_exclude_unit
  t0_stats_to_prometheus_unit
  t0_anchor_to_prometheus_unit
  t0_cache_split_unit
  t0_cycle_metrics_unit
  t0_helper_lock_unit
  t0_self_swap_identity_unit
  t0_image_identity_unit
  t0_verify_once_unit
  t0_identity_defaults_unit
  t_discover
  t_discover_waits_for_recreating_resolver
  t_config_fingerprint_handles_spaces
  t_validate
  t_validate_dnssec_optional
  t4_invalid_conf_rejected
  t5_healthcheck_breaking_conf
  t_canary_lifecycle
  t_canary_replicates_declared_runtime
  t_canary_refused_in_host_network_mode
  t_host_mode_cycle_refused_early
  t_modes
  t_loop_sigterm
  t_metrics_scrape
  t1_image_update_actually_lands
  t1b_moved_tag_update_actually_lands
  t2_noop_second_cycle
  t3_config_change_triggers
  t_cache_preserved_across_swap
  t_verify_live_identities
  t_verify_key_accepts_signed
  t6_unsigned_image_refused
  t8_major_bump_refused
  t_self_update_applies
  t_self_update_rolls_back
  t_self_update_trust
  t_self_update_despite_refused_resolver
  t_self_update_after_tag_moved
  t_idle_cycles_keep_local_names
  t_prune_keeps_tagged_images
  t_idle_cycle_registry_traffic
  t_baseline_image_verified
  t_swap_pins_verified_digest
  t7a_failed_swap_is_loud
  t7b_rollback_restores_previous_digest
  t7c_config_rollback_replaces_container
  t_cycles_after_rollback
  t_major_guard_tag_only
  t_downgrade_refused
  t_rollback_without_registry
  t_interrupted_swap_recovery
  t_swap_killed_mid_recreate
  t_stale_intents_resolve
"
# ONLY="t_a t_b" runs a subset while iterating on one test; the default is
# the whole suite, which is what CI runs.
for t in ${ONLY:-$ALL_TESTS}; do
  info "$t"
  "$t"
done
echo "ALL UPDATER TESTS PASSED"
