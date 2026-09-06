#!/usr/bin/env bash
# Shared helpers for the updater integration suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER_IMAGE="${UPDATER_IMAGE:-unbound-autoupdate:test}"
TEST_TMPDIR="${TEST_TMPDIR:-/tmp}"

# Every fixture directory ever created, so a leftover one can be reaped at
# script exit. This matters because fail() below calls `exit`, which skips
# any `trap ... RETURN` a test registered on its own fixture: a `return`
# never happens, so that trap never fires. Without this safety net, a failing
# assertion leaks the fixture's containers, volumes and network, which would
# poison every test that runs after it.
declare -a _FIXTURE_DIRS=()

# Every image reference a test has locally `docker tag`-ed to a digest other
# than what the registry actually serves (to simulate a moved tag without
# ever editing a compose file). Same reasoning as _FIXTURE_DIRS: fail()'s
# `exit` skips a test's own `trap ... RETURN`, so a setup assertion tripping
# between the `docker tag` and the test's own restore would otherwise leave
# the HOST's real tag rewritten — outliving the test run entirely, since this
# mutates a global Docker daemon-wide reference, not anything scoped to a
# fixture. retag_track records it here instead of relying on the test's own
# cleanup to run.
declare -a _MOVED_TAGS=()
retag_track() { _MOVED_TAGS+=("$1"); }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
info() { echo "---- $*"; }

# fixture_create <dir> <image-ref> [host-udp-port] — writes a compose project
# and starts it. When a port is given the resolver publishes it on loopback,
# which is the one axis on which a canary and production genuinely differ.
# The project dir is bind-mounted into the sidecar at the SAME absolute path,
# which is what makes Compose's relative bind-mount resolution line up.
fixture_create() {
  local dir="$1" ref="$2" port="${3:-}" ports=""
  [ -n "$port" ] && ports=$'\n    ports:\n      - "127.0.0.1:'"$port"$':53/udp"'
  mkdir -p "$dir"
  _FIXTURE_DIRS+=("$dir")
  cp "$REPO_ROOT/unbound.conf" "$dir/unbound.conf"
  cat > "$dir/docker-compose.yml" <<YML
services:
  unbound:
    image: $ref$ports
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    volumes:
      - state:/var/lib/unbound
      - ./unbound.conf:/etc/unbound/unbound.conf:ro
  updater:
    image: $UPDATER_IMAGE
    entrypoint: ["sleep", "infinity"]
    environment:
      STATE_DIR: /var/lib/unbound-autoupdate
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $dir:$dir:ro
      - ustate:/var/lib/unbound-autoupdate
volumes:
  state:
  ustate:
YML
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" up -d ) >/dev/null
}

fixture_project() { basename "$1" | tr -cd 'a-z0-9'; }

fixture_destroy() {
  local dir="$1"
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" down -v --remove-orphans ) >/dev/null 2>&1 || true
  rm -rf "$dir"
}

# fixture_set_image <dir> <ref> — rewrites the declared image in place,
# simulating a new release becoming available.
fixture_set_image() {
  sed -i.bak "s|^    image: .*unbound-distroless.*|    image: $2|" "$1/docker-compose.yml"
  rm -f "$1/docker-compose.yml.bak"
}

# updater_exec <dir> <command…> — runs a command inside the fixture's sidecar.
updater_exec() {
  local dir="$1"; shift
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
    -f "$dir/docker-compose.yml" exec -T updater "$@"
}

# running_ref <dir> — the image digest the resolver container actually runs.
running_ref() {
  local cid
  cid=$(docker compose -p "$(fixture_project "$1")" --project-directory "$1" \
        -f "$1/docker-compose.yml" ps -q unbound)
  docker inspect "$cid" --format '{{.Image}}'
}

# OLD_REF is an immutable published revision; MOVING_REF is the tag users
# actually track. A cycle must move the container from one to the other.
OLD_REF="${OLD_REF:-esitcparis/unbound-distroless:1.26.0-r0}"
MOVING_REF="${MOVING_REF:-esitcparis/unbound-distroless:1}"

# updater_run <dir> [env=value…] — runs one cycle; echoes exit code on stdout.
updater_run() {
  local dir="$1"; shift
  local envs=()
  local kv; for kv in "$@"; do envs+=(-e "$kv"); done
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
    -f "$dir/docker-compose.yml" exec -T "${envs[@]}" updater \
    /usr/local/bin/unbound-autoupdate
}

# _fixture_reap_leftovers — safety net run at script exit. A fixture whose
# test already tore it down via its own RETURN trap has no directory left,
# so it is skipped here; anything still on disk (an aborted or failed test)
# gets torn down so it cannot leak into the next run. Capture and re-exit
# with the original status: an EXIT trap's own exit status otherwise becomes
# the script's, which would silently turn a passing run into a failing one
# whenever the loop's last command (an already-cleaned-up fixture) is false.
# Also restores every tag a test rewrote via retag_track, for the same
# reason — this fires on EXIT, which fail()'s own `exit` cannot skip, unlike
# a test's `trap ... RETURN`.
_fixture_reap_leftovers() {
  local status=$? d ref
  for d in "${_FIXTURE_DIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && fixture_destroy "$d"
  done
  for ref in "${_MOVED_TAGS[@]:-}"; do
    [ -n "$ref" ] && docker pull -q "$ref" >/dev/null 2>&1 || true
  done
  exit "$status"
}
trap _fixture_reap_leftovers EXIT
