#!/usr/bin/env bash
# Shared helpers for the updater integration suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER_IMAGE="${UPDATER_IMAGE:-unbound-autoupdate:test}"
TEST_TMPDIR="${TEST_TMPDIR:-/tmp}"

REGISTRY_NAME="upd-test-registry"
REGISTRY_HOST="127.0.0.1:5000"

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

# Every container name a test started purely to occupy a host port (T7a's
# environmental "blocker"). Same reasoning as _FIXTURE_DIRS and _MOVED_TAGS:
# fail()'s `exit` skips a test's own `trap ... RETURN`, and this specific
# container holds a real DNS port on the host — a leftover one breaks every
# later run that needs that port, not just the fixture that created it.
declare -a _BLOCKER_CONTAINERS=()
blocker_track() { _BLOCKER_CONTAINERS+=("$1"); }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
info() { echo "---- $*"; }

# fixture_create <dir> <image-ref> — writes a compose project and starts it.
# The project dir is bind-mounted into the sidecar at the SAME absolute path,
# which is what makes Compose's relative bind-mount resolution line up.
# No port-publishing knob on purpose: T7a, the one test that needs a published
# port, must add it at UPDATE time rather than at creation time (see there),
# so a knob here would only ever be dead code.
#
# FIXTURE_UNBOUND_EXTRA / FIXTURE_UPDATER_EXTRA: extra YAML lines (indented
# four spaces, i.e. service-level keys) appended to the respective service,
# for tests that need a differently shaped project at CREATION time — a
# read-only rootfs, a host-networked sidecar. Empty by default.
#
# FIXTURE_UPDATER_IMAGE: image reference for BOTH sidecar services (updater and
# metrics); defaults to the locally built test image. The self-update tests
# point it at the throwaway registry so that `compose pull` has somewhere to
# pull from and the running sidecar carries a repository digest.
fixture_create() {
  local dir="$1" ref="$2"
  mkdir -p "$dir"
  _FIXTURE_DIRS+=("$dir")
  cp "$REPO_ROOT/unbound.conf" "$dir/unbound.conf"
  cat > "$dir/docker-compose.yml" <<YML
services:
  unbound:
    image: $ref
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    volumes:
      - state:/var/lib/unbound
      - ./unbound.conf:/etc/unbound/unbound.conf:ro
${FIXTURE_UNBOUND_EXTRA:-}
  updater:
    image: ${FIXTURE_UPDATER_IMAGE:-$UPDATER_IMAGE}
    command: ["idle"]
    environment:
      STATE_DIR: /var/lib/unbound-autoupdate
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $dir:$dir:ro
      - ustate:/var/lib/unbound-autoupdate
${FIXTURE_UPDATER_EXTRA:-}
  metrics:
    image: ${FIXTURE_UPDATER_IMAGE:-$UPDATER_IMAGE}
    command: ["metrics"]
    ports:
      - "127.0.0.1::9167"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ustate:/var/lib/unbound-autoupdate:ro
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

# fixture_set_image_raw <dir> <old-substring> <new-ref> — like
# fixture_set_image, but matches on a caller-supplied substring instead of
# the literal "unbound-distroless", so it also works on refs pointing at the
# throwaway registry (registry_publish's crafted images).
fixture_set_image_raw() {
  sed -i.bak "s|^    image: .*$2.*|    image: $3|" "$1/docker-compose.yml"
  rm -f "$1/docker-compose.yml.bak"
}

# registry_up — a throwaway registry so crafted images are genuinely pullable.
# Without it `compose pull` fails first and the guard under test is never
# reached (see T6/T8 below).
registry_up() {
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$REGISTRY_NAME" -p 127.0.0.1:5000:5000 \
    registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
  local _i
  for _i in $(seq 1 30); do
    curl -fsS "http://$REGISTRY_HOST/v2/" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "local registry never became ready"
}

registry_down() { docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true; }

# registry_publish <dockerfile-text> <repo:tag> — builds and pushes, echoes
# the ref. The repo name must contain "unbound", which discovery requires to
# recognise the target service.
registry_publish() {
  local ref="$REGISTRY_HOST/$2"
  printf '%s\n' "$1" | docker build -q -t "$ref" - >/dev/null
  docker push -q "$ref" >/dev/null
  printf '%s\n' "$ref"
}

# registry_forward <dir> — make 127.0.0.1:5000 INSIDE the fixture's sidecar
# reach the throwaway registry. The daemon pulls through the host's published
# port, but cosign runs inside the sidecar where 127.0.0.1 is the container's
# own loopback. The registry is connected to the fixture network under the
# alias "registry" and a relay listens on the sidecar's own loopback for the
# life of the fixture. Without this, an unsigned-image test fails on
# "connection refused" instead of "no signatures found" — the right verdict
# for the wrong reason.
#
# socat, installed into the test container at run time and NEVER into the
# image: a busybox `nc -l -p 5000 -e nc registry 5000` loop serves exactly
# one connection and then has to be respawned, and cosign's first request to
# a loopback registry is an HTTPS probe immediately followed by the real HTTP
# request — the second one lands in that gap and is refused. socat's `fork`
# accepts them back to back.
registry_forward() {
  local dir="$1" net
  net="$(fixture_project "$dir")_default"
  docker network connect --alias registry "$net" "$REGISTRY_NAME" >/dev/null 2>&1 || true
  updater_exec "$dir" /bin/sh -c \
    'command -v socat >/dev/null 2>&1 || apk add --no-cache socat >/dev/null 2>&1; \
     nohup socat TCP-LISTEN:5000,fork,reuseaddr TCP:registry:5000 >/dev/null 2>&1 &'
  # Prove the relay before any test relies on it.
  local _i
  for _i in $(seq 1 10); do
    updater_exec "$dir" /bin/sh -c 'wget -qO- http://127.0.0.1:5000/v2/ >/dev/null 2>&1' && return 0
    sleep 1
  done
  fail "registry relay inside the sidecar never came up"
}

# cosign_test_keys <dir> — a throwaway key pair in the sidecar's state volume,
# so the same path is valid inside the updater container, the metrics
# container and the self-update helper. Empty password; never leaves /tmp.
cosign_test_keys() {
  updater_exec "$1" /bin/sh -c \
    'cd /var/lib/unbound-autoupdate && rm -f testkey.key testkey.pub && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix testkey >/dev/null 2>&1'
}
# shellcheck disable=SC2034  # read by tests/updater.sh, which sources this file
TEST_PUBKEY=/var/lib/unbound-autoupdate/testkey.pub

# registry_sign <dir> <ref> — sign <ref> in the throwaway registry with the
# test key, from inside the sidecar (which is where the relay lives). No
# transparency-log upload: this is a private, ephemeral registry.
# --use-signing-config=false: cosign v3 (the version the image now embeds)
# defaults to the Sigstore public signing config, which mandates a
# transparency log and so rejects --tlog-upload=false outright. Turning the
# signing config off is what makes "sign with a local key, log nothing"
# expressible in v3; it only affects how these throwaway fixtures are signed,
# never how the sidecar verifies them.
registry_sign() {
  updater_exec "$1" /bin/sh -c \
    "COSIGN_PASSWORD='' cosign sign --key /var/lib/unbound-autoupdate/testkey.key --use-signing-config=false --tlog-upload=false --yes '$2' >/dev/null 2>&1" \
    || fail "could not sign $2 with the test key"
}

# promtool_check <file> — the Prometheus text exposition format has a
# reference parser; use it rather than hand-rolled greps. Exit 3 means lint
# problems (a metric without HELP, a bad name), which count as failures.
PROMTOOL_IMAGE="prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996"
promtool_check() {
  docker run --rm -i --entrypoint promtool "$PROMTOOL_IMAGE" check metrics < "$1"
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

# fixture_service_cid <dir> <service> — container id the service runs, or
# empty when it has no running container. The id, not the image, is what
# tells a real recreation from Compose deciding it had nothing to do.
fixture_service_cid() {
  docker compose -p "$(fixture_project "$1")" --project-directory "$1" \
    -f "$1/docker-compose.yml" ps -q "$2" 2>/dev/null | head -1
}

# fixture_service_image_id <dir> <service> — image ID the service's container
# runs, or empty when it has no running container.
fixture_service_image_id() {
  local cid
  cid=$(fixture_service_cid "$1" "$2")
  [ -n "$cid" ] || { echo ""; return 0; }
  docker inspect "$cid" --format '{{.Image}}' 2>/dev/null || echo ""
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
# a test's `trap ... RETURN`. And always tears down the throwaway registry:
# a test that fails between registry_up and its own (skipped) RETURN trap
# would otherwise leave it holding port 5000, breaking every subsequent run
# on this machine. registry_down is a no-op if nothing was ever started.
# Also removes every container a test started purely to hold a host port
# (T7a's blocker), for the same reason: a leftover one breaks every later
# run that needs that port, not just the fixture that started it.
_fixture_reap_leftovers() {
  local status=$? d ref
  for d in "${_FIXTURE_DIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && fixture_destroy "$d"
  done
  for ref in "${_MOVED_TAGS[@]:-}"; do
    [ -n "$ref" ] && docker pull -q "$ref" >/dev/null 2>&1 || true
  done
  for ref in "${_BLOCKER_CONTAINERS[@]:-}"; do
    [ -n "$ref" ] && docker rm -f "$ref" >/dev/null 2>&1 || true
  done
  registry_down
  exit "$status"
}
trap _fixture_reap_leftovers EXIT
