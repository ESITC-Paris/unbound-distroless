#!/usr/bin/env bash
# Port-53 behaviour: pins what the file capability on /usr/local/sbin/unbound
# (cap_net_bind_service=+ep, see the Dockerfile) does and does not do under
# the hardening options people actually combine. Each case asserts the
# observed outcome; if one changes (new engine, new runtime), this test fails
# and the documentation follows the test, not the other way round.
# Every "could not determine" path is an explicit FAIL or a logged SKIP,
# never a silent pass.
#
#   A. Proves: on a bridge network, the documented recipe (cap_drop ALL +
#      cap_add NET_BIND_SERVICE + no-new-privileges) binds :53 BY THE
#      CAPABILITY. Docker sets ip_unprivileged_port_start=0 in container
#      namespaces, which would let anyone bind :53 and prove nothing, so the
#      case forces it back to the kernel default 1024 and reads it back.
#      Also asserts PID 1 is unbound, UID 65532, NoNewPrivs=1, CapPrm=CapEff=
#      exactly NET_BIND_SERVICE, CapAmb=0, and that :53 answers.
#      Never skipped.
#   B. Proves: with cap_drop ALL and no cap_add, with and without
#      no-new-privileges, the container never starts Unbound: the file
#      capability requests a bit outside the bounding set, so the runtime's
#      execve of /usr/local/sbin/unbound is refused with EPERM. Asserted as:
#      not running, non-zero exit, no "start of service", and an error that
#      names the binary and EPERM ("operation not permitted", in any case,
#      as runc and crun word it). Never skipped.
#   C. Proves: on the host network, the documented recipe binds :53 in the
#      HOST namespace, where the host's sysctl applies. It binds only
#      127.0.0.153 (a loopback address nothing listens on; all of 127/8 is
#      local on Linux) with a minimal configuration, so it can neither take
#      nor shadow the runner's 127.0.0.53 (systemd-resolved) or anything on
#      0.0.0.0:53. The bind is always asserted; that the CAPABILITY did it is
#      asserted only when the host's ip_unprivileged_port_start is > 53 —
#      otherwise that sub-assertion is a logged SKIP (any process could have
#      bound). Whole case skipped, logged, with PORT53_SKIP_HOSTNET=1.
#
# A helper container (the digest-pinned Debian build base from
# .build-state.json; override with PORT53_HELPER_IMAGE) joins the resolver's
# PID and network namespaces to read the effective sysctl and PID 1's
# credentials — the image under test has no shell to read them itself.
#
# Usage: tests/port53.sh [image-tag]   (needs docker and dig)
set -euo pipefail

IMG="${1:-unbound-distroless:test}"
HERE=$(cd "$(dirname "$0")" && pwd)
PFX="unbound-port53-$$"
HOSTNET_ADDR=127.0.0.153

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
CREATED=()
TMPDIR_P53=$(mktemp -d)
cleanup() {
  for c in "${CREATED[@]+"${CREATED[@]}"}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  rm -rf "$TMPDIR_P53"
}
trap cleanup EXIT

command -v dig >/dev/null || fail "dig not found (install bind9-dnsutils / dnsutils)"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "image $IMG not found — build it first"

if [ -z "${PORT53_HELPER_IMAGE:-}" ]; then
  DIGEST=$(sed -n 's/.*"debian"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$HERE/../.build-state.json")
  [ -n "$DIGEST" ] || fail "no debian digest in .build-state.json (set PORT53_HELPER_IMAGE)"
  PORT53_HELPER_IMAGE="debian:trixie@$DIGEST"
fi
docker image inspect "$PORT53_HELPER_IMAGE" >/dev/null 2>&1 \
  || docker pull -q "$PORT53_HELPER_IMAGE" >/dev/null || fail "cannot pull helper $PORT53_HELPER_IMAGE"

# Print the effective sysctl and PID 1's credentials as seen from inside the
# container's namespaces.
probe() {  # probe <container>
  docker run --rm --pid "container:$1" --network "container:$1" \
    --cap-drop ALL --security-opt no-new-privileges "$PORT53_HELPER_IMAGE" \
    sh -c 'echo "sysctl $(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)";
           grep -E "^(Uid|Gid|NoNewPrivs|CapPrm|CapEff|CapAmb):" /proc/1/status;
           echo "argv0 $(tr "\\0" "\\n" < /proc/1/cmdline | head -n 1)"'
}
field() { awk -v k="$1" '$1 == k || $1 == k":" { print $2; exit }' <<<"$2"; }

wait_started() {  # wait_started <container>: until Unbound logs that its ports are open
  for _i in $(seq 1 30); do
    docker logs "$1" 2>&1 | grep -q 'start of service' && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] || return 1
    sleep 1
  done
  return 1
}

# ── A. bridge network, documented recipe, sysctl at the kernel default ──────
A="$PFX-a"; CREATED+=("$A")
docker run -d --name "$A" \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  --sysctl net.ipv4.ip_unprivileged_port_start=1024 \
  -p 127.0.0.1::53/udp \
  "$IMG" >/dev/null
wait_started "$A" || { docker logs "$A" 2>&1 | tail -20; fail "A: Unbound did not start (bind :53 refused?)"; }
P=$(probe "$A") || fail "A: helper probe failed: $P"
[ "$(field sysctl "$P")" = "1024" ] || fail "A: ip_unprivileged_port_start is not 1024 in the container: $P"
[ "$(field NoNewPrivs "$P")" = "1" ] || fail "A: no-new-privileges not in effect: $P"
[ "$(field Uid "$P")" = "65532" ] || fail "A: PID 1 does not run as UID 65532: $P"
[ "$(field argv0 "$P")" = "/usr/local/sbin/unbound" ] || fail "A: PID 1 is not unbound: $P"
# 0x400 = 1 << CAP_NET_BIND_SERVICE (10): exactly that bit, nothing else, and
# no ambient set (the capability comes from the file, not from inheritance).
[ "$(field CapEff "$P")" = "0000000000000400" ] || fail "A: CapEff is not exactly NET_BIND_SERVICE: $P"
[ "$(field CapPrm "$P")" = "0000000000000400" ] || fail "A: CapPrm is not exactly NET_BIND_SERVICE: $P"
[ "$(field CapAmb "$P")" = "0000000000000000" ] || fail "A: unexpected ambient capabilities: $P"
HP=$(docker port "$A" 53/udp | head -n 1 | sed 's/.*://') || true
[ -n "$HP" ] || fail "A: could not determine the published host port for 53/udp"
# localhost. is answered from Unbound's built-in local zone: no Internet needed.
dig @127.0.0.1 -p "$HP" +time=3 +tries=3 localhost. A | grep -qE '^localhost\.\s.*\sA\s+127\.0\.0\.1' \
  || fail "A: no answer from :53 through the published port"
pass "A: bridge + cap_drop ALL + cap_add NET_BIND_SERVICE + no-new-privileges binds :53 with ip_unprivileged_port_start=1024 (UID 65532, CapEff=0x400, NoNewPrivs=1)"

# ── B. cap_drop ALL without cap_add: refused at exec ─────────────────────────
for nnp in no yes; do
  B="$PFX-b-$nnp"; CREATED+=("$B")
  opts=(--cap-drop=ALL)
  [ "$nnp" = yes ] && opts+=(--security-opt no-new-privileges)
  # Depending on the engine the exec error surfaces in `docker run` itself or
  # only in the container state: collect both.
  OUT=$(docker run -d --name "$B" "${opts[@]}" "$IMG" 2>&1) && RC=0 || RC=$?
  for _i in $(seq 1 10); do
    [ "$(docker inspect -f '{{.State.Status}}' "$B" 2>/dev/null)" = "running" ] || break
    sleep 1
  done
  docker inspect "$B" >/dev/null 2>&1 || fail "B($nnp): container was not created (docker run rc=$RC): $OUT"
  STATE=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$B")
  ERR="$OUT $(docker inspect -f '{{.State.Error}}' "$B") $(docker logs "$B" 2>&1 || true)"
  [ "${STATE%% *}" != "running" ] || fail "B($nnp): container still running without NET_BIND_SERVICE"
  [ "${STATE##* }" != "0" ] || fail "B($nnp): container exited 0 (state: $STATE)"
  grep -q 'start of service' <<<"$ERR" && fail "B($nnp): Unbound started — expected an exec refusal: $ERR"
  grep -qiE '/usr/local/sbin/unbound.*operation not permitted' <<<"$ERR" \
    || fail "B($nnp): failure is not the expected EPERM exec refusal (docker run rc=$RC, state: $STATE): $ERR"
  pass "B: cap_drop ALL without cap_add NET_BIND_SERVICE (no-new-privileges: $nnp) is refused at exec with EPERM (state: $STATE)"
done

# ── C. host network, documented recipe, loopback-only bind ──────────────────
if [ "${PORT53_SKIP_HOSTNET:-0}" = "1" ]; then
  skip "C: host-network case skipped (PORT53_SKIP_HOSTNET=1)"
else
  cat > "$TMPDIR_P53/hostnet.conf" <<EOF
server:
  interface: $HOSTNET_ADDR
  port: 53
  do-ip6: no
  username: ""
  chroot: ""
  pidfile: ""
  use-syslog: no
  logfile: ""
  verbosity: 1
  access-control: $HOSTNET_ADDR/32 allow
remote-control:
  control-enable: no
EOF
  chmod 0644 "$TMPDIR_P53/hostnet.conf"
  C="$PFX-c"; CREATED+=("$C")
  docker run -d --name "$C" --network host \
    --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
    --security-opt no-new-privileges \
    -v "$TMPDIR_P53/hostnet.conf:/etc/unbound/port53-hostnet.conf:ro" \
    --entrypoint /usr/local/sbin/unbound \
    "$IMG" -d -c /etc/unbound/port53-hostnet.conf >/dev/null
  if ! wait_started "$C"; then
    LOGS=$(docker logs "$C" 2>&1 | tail -20)
    grep -q 'Address already in use' <<<"$LOGS" \
      && fail "C: $HOSTNET_ADDR:53 is already in use on this host — pick another HOSTNET_ADDR; nothing was disturbed"
    echo "$LOGS" >&2
    fail "C: Unbound did not start in the host network namespace"
  fi
  P=$(probe "$C") || fail "C: helper probe failed: $P"
  [ "$(field NoNewPrivs "$P")" = "1" ] || fail "C: no-new-privileges not in effect: $P"
  [ "$(field CapEff "$P")" = "0000000000000400" ] || fail "C: CapEff is not exactly NET_BIND_SERVICE: $P"
  HOST_SYSCTL=$(field sysctl "$P")
  case "$HOST_SYSCTL" in
    ''|*[!0-9]*) fail "C: could not read the host's ip_unprivileged_port_start (got '$HOST_SYSCTL'): $P" ;;
  esac
  pass "C: host network + cap_drop ALL + cap_add NET_BIND_SERVICE + no-new-privileges binds $HOSTNET_ADDR:53 (CapEff=0x400, NoNewPrivs=1)"
  if [ "$HOST_SYSCTL" -gt 53 ]; then
    pass "C: the capability did it (host ip_unprivileged_port_start=$HOST_SYSCTL)"
  else
    skip "C: capability path not isolated: this host's ip_unprivileged_port_start=$HOST_SYSCTL lets any process bind :53"
  fi
fi

echo "ALL PORT-53 TESTS PASSED"
