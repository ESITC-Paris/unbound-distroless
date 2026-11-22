#!/usr/bin/env bash
# Runs the README's two quick-start blocks as written, against a given image,
# so the README cannot drift from what works.
#
# The blocks are read from README.md (the fenced block after the
# `<!-- quickstart:try` and `<!-- quickstart:run` markers) and every line is
# executed in order, with only these substitutions — each must match, or the
# test fails, so a README edit that moves them cannot silently disable one:
#
#   try  the published image reference -> the image under test ($1);
#        the container name unbound-try  -> a unique name;
#        host port 5053                  -> a free ephemeral port.
#   run  the Compose file the README prints (the block after
#        `<!-- quickstart:compose`) is saved as docker-compose.yml, after
#        `docker compose config` has shown it to be the same project as this
#        checkout's docker-compose.yml;
#        `docker compose …` runs with COMPOSE_PROJECT_NAME (unique) and
#        COMPOSE_FILE adding an override that sets only the image, the
#        container name and the published ports;
#        `dig @127.0.0.1 …`               -> `dig @127.0.0.1 -p <port> …`.
#
# Port 53 of the host is never bound: the override replaces the published
# "53:53" with 127.0.0.1:<ephemeral>:53, so a CI runner's systemd-resolved
# (127.0.0.53:53) and anything else on the host's :53 are left alone. The
# file's own ports are asserted to be 53:53/udp and 53:53/tcp, and the
# running container's hardening (capabilities, no-new-privileges, read-only
# root) is asserted from `docker inspect`, so the README's description of the
# file is tested too.
#
# A `dig` line is retried for up to 60 s (a cold resolver can SERVFAIL while
# priming; the README says to run it again). Its expected result is fixed by
# the test, not parsed from the comment: a `+dnssec` query must be NOERROR
# with the `ad` flag, a `dnssec-failed.org` query must be SERVFAIL.
#
# Usage: tests/quickstart.sh <image>   (needs docker, docker compose, dig)
set -euo pipefail

IMG="${1:?usage: tests/quickstart.sh <image>}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
README="$ROOT/README.md"
PUBLISHED=esitcparis/unbound-distroless

ID="qs-$$-$RANDOM"
TRY_NAME="unbound-$ID-try"
RUN_NAME="unbound-$ID-run"
export COMPOSE_PROJECT_NAME="unbound-$ID"
WORK=$(mktemp -d)

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cleanup() {
  docker rm -f "$TRY_NAME" >/dev/null 2>&1 || true
  if [ -n "${COMPOSE_FILE:-}" ]; then
    (cd "$WORK/run" 2>/dev/null && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

command -v jq >/dev/null || fail "jq not found"
command -v dig >/dev/null || fail "dig not found (install bind9-dnsutils / dnsutils)"
docker compose version >/dev/null 2>&1 || fail "docker compose not found"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "image $IMG not found — build it first"

# block <name>: the lines of the fenced block that follows the marker.
block() {
  awk -v m="<!-- quickstart:$1" '
    index($0, m) == 1 { found = 1; next }
    found && !inside && /^```/ { inside = 1; next }
    inside && /^```/ { exit }
    inside { print }
  ' "$README"
}

# A host port for the published DNS port: random in 20000-49999, retried
# while something already accepts TCP connections on it.
free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(( 20000 + RANDOM % 30000 ))
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
  done
  fail "no free port found"
}

# check_dig <command…>: run a dig line until its expected result appears.
check_dig() {
  local line="$1" out expect
  case "$line" in
    *dnssec-failed.org*) expect='status: SERVFAIL' ;;
    *+dnssec*)           expect='ad' ;;
    *) fail "dig line with no known expectation: $line" ;;
  esac
  for _ in $(seq 1 12); do
    out=$(eval "$line" 2>&1) || true
    if [ "$expect" = ad ]; then
      grep -q 'status: NOERROR' <<<"$out" && grep -qE '^;; flags:[^;]* ad[ ;]' <<<"$out" && return 0
    else
      grep -q "$expect" <<<"$out" && return 0
    fi
    sleep 5
  done
  echo "$out" >&2
  fail "'$line' never gave the expected result ($expect)"
}

# subst <text> <from> <to>: literal replacement that must happen.
subst() {
  local text="$1" from="$2" to="$3"
  [[ "$text" == *"$from"* ]] || fail "expected '$from' in: $text"
  printf '%s' "${text//"$from"/"$to"}"
}

# ── Tier 1: Try it ────────────────────────────────────────────────────────────
TRY=$(block try)
[ -n "$TRY" ] || fail "no quickstart:try block in README.md"
TRY_PORT=$(free_port)
grep -q -- "--name unbound-try " <<<"$TRY" || fail "try: the container is not named unbound-try"
grep -q -- "127.0.0.1:5053:53/udp" <<<"$TRY" || fail "try: not published on 127.0.0.1:5053/udp"
grep -q "+dnssec" <<<"$TRY" || fail "try: no DNSSEC-validated query"
grep -q "dnssec-failed.org" <<<"$TRY" || fail "try: no bogus-signature query"

mkdir -p "$WORK/try"
cd "$WORK/try"
while IFS= read -r line; do
  [ -n "${line// /}" ] || continue
  case "$line" in
    "docker run "*)
      cmd=$(subst "$line" "unbound-try" "$TRY_NAME")
      cmd=$(subst "$cmd" "$PUBLISHED:latest" "$IMG")
      cmd=$(subst "$cmd" "127.0.0.1:5053:" "127.0.0.1:$TRY_PORT:")
      eval "$cmd" >/dev/null ;;
    "docker stop "*)
      eval "$(subst "$line" "unbound-try" "$TRY_NAME")" >/dev/null ;;
    dig\ *)
      check_dig "$(subst "$line" "-p 5053" "-p $TRY_PORT")" ;;
    *) fail "try: unexpected line (extend tests/quickstart.sh): $line" ;;
  esac
done <<<"$TRY"
# The last line stopped it; --rm removes it.
for _ in $(seq 1 10); do
  docker container inspect "$TRY_NAME" >/dev/null 2>&1 || break
  sleep 1
done
docker container inspect "$TRY_NAME" >/dev/null 2>&1 && fail "try: container still present after docker stop (--rm)"
pass "try: docker run on 127.0.0.1, NOERROR with ad, bogus signature SERVFAIL, stopped and removed"

# ── Tier 2: Run it ────────────────────────────────────────────────────────────
RUN=$(block run)
[ -n "$RUN" ] || fail "no quickstart:run block in README.md"
RUN_PORT=$(free_port)

# The file the README prints is the shipped one: same project once Compose
# has parsed both (comments and YAML layout aside).
F="$ROOT/docker-compose.yml"
mkdir -p "$WORK/cmp/readme/unbound" "$WORK/cmp/shipped/unbound" "$WORK/run"
block compose > "$WORK/cmp/readme/unbound/docker-compose.yml"
[ -s "$WORK/cmp/readme/unbound/docker-compose.yml" ] || fail "no quickstart:compose block in README.md"
cp "$F" "$WORK/cmp/shipped/unbound/docker-compose.yml"
for side in readme shipped; do
  (cd "$WORK/cmp/$side/unbound" && env -u COMPOSE_PROJECT_NAME docker compose config --format json) \
    > "$WORK/cmp/$side.json" 2>"$WORK/cmp/$side.err" \
    || fail "run: docker compose config refused the $side file: $(cat "$WORK/cmp/$side.err")"
done
diff <(jq -S . "$WORK/cmp/readme.json") <(jq -S . "$WORK/cmp/shipped.json") >&2 \
  || fail "run: the Compose file in README.md differs from docker-compose.yml"
pass "run: the Compose file in README.md is the shipped docker-compose.yml"

# The shipped file, before any override: the README says port 53, hardened.
grep -qE "^[[:space:]]*image: $PUBLISHED:" "$F" || fail "docker-compose.yml: image is not $PUBLISHED:<tag>"
grep -qF -- '- "53:53/udp"' "$F" || fail "docker-compose.yml: does not publish 53:53/udp"
grep -qF -- '- "53:53/tcp"' "$F" || fail "docker-compose.yml: does not publish 53:53/tcp"

OVERRIDE="$WORK/override.yml"
cat > "$OVERRIDE" <<EOF
services:
  unbound:
    image: $IMG
    container_name: $RUN_NAME
    ports: !override
      - "127.0.0.1:$RUN_PORT:53/udp"
      - "127.0.0.1:$RUN_PORT:53/tcp"
EOF

cd "$WORK/run"
cp "$WORK/cmp/readme/unbound/docker-compose.yml" docker-compose.yml
while IFS= read -r line; do
  [ -n "${line// /}" ] || continue
  case "$line" in
    "docker compose "*)
      # Set here, after the README's own `cd`: relative to the project dir.
      export COMPOSE_FILE="docker-compose.yml:$OVERRIDE"
      eval "$line" >/dev/null 2>&1 || { docker compose logs 2>&1 | tail -20; fail "run: '$line' failed"; } ;;
    dig\ *)
      check_dig "$(subst "$line" "@127.0.0.1 " "@127.0.0.1 -p $RUN_PORT ")" ;;
    *) fail "run: unexpected line (extend tests/quickstart.sh): $line" ;;
  esac
done <<<"$RUN"
[ -n "${COMPOSE_FILE:-}" ] || fail "run: no 'docker compose' line"

# Hardening as the README describes it, read from the running container.
HC=$(docker inspect -f '{{json .HostConfig.CapDrop}} {{json .HostConfig.CapAdd}} {{json .HostConfig.SecurityOpt}} {{.HostConfig.ReadonlyRootfs}}' "$RUN_NAME")
grep -q '\["ALL"\]' <<<"$HC" || fail "run: capabilities not dropped: $HC"
grep -q 'NET_BIND_SERVICE' <<<"$HC" || fail "run: NET_BIND_SERVICE not added: $HC"
grep -q 'no-new-privileges:true' <<<"$HC" || fail "run: no-new-privileges not set: $HC"
grep -q ' true$' <<<"$HC" || fail "run: root filesystem is not read-only: $HC"
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$RUN_NAME")" = healthy ] && break
  sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$RUN_NAME")" = healthy ] || fail "run: container never became healthy"
pass "run: docker compose up from the README's file (read-only, cap_drop ALL + NET_BIND_SERVICE, no-new-privileges, healthy), NOERROR with ad, bogus signature SERVFAIL"

echo "ALL QUICKSTART TESTS PASSED"
