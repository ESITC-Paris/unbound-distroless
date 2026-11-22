#!/usr/bin/env bash
# Shared helpers for the updater integration suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER_IMAGE="${UPDATER_IMAGE:-unbound-autoupdate:test}"
TEST_TMPDIR="${TEST_TMPDIR:-/tmp}"

# Per run: the daemon is shared, and registry_up removes any container of this
# name before starting its own — a fixed name would kill a concurrent run's.
REGISTRY_NAME="upd-test-registry-$$"
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

# Every image this suite built under a name of its own (hooks_image), removed
# at exit for the same reason as the rest: fail()'s `exit` skips RETURN traps.
declare -a _BUILT_IMAGES=()
_TRACK_FILE="$TEST_TMPDIR/upd-built-images-$$"

# hooks_image — the test image with the suite's one test hook added, built
# once per run and named in HOOKS_IMAGE (a variable, not output: called in a
# command substitution, the cleanup registration would be lost with the
# subshell). The shipped script reads no test variable at all; this derived
# copy inserts, at the top of post_swap_validated, a check of
# _TEST_FORCE_POSTSWAP_FAIL that forces the post-swap verdict to FAIL, so the
# rollback can be exercised deterministically. Same repository as
# UPDATER_IMAGE, so discovery treats it as the sidecar's own image.
hooks_image() {
  local ref="${UPDATER_IMAGE%:*}:hooks-$$"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    printf '%s\n' "FROM $UPDATER_IMAGE" \
      "RUN sed -i '/^post_swap_validated() {\$/a\\  [ \"\${_TEST_FORCE_POSTSWAP_FAIL:-0}\" = 1 ] \&\& { log_warn \"test hook: post-swap verdict forced to FAIL\"; return 1; }' /usr/local/bin/unbound-autoupdate \\" \
      " && grep -q '_TEST_FORCE_POSTSWAP_FAIL' /usr/local/bin/unbound-autoupdate" \
      | docker build -q -t "$ref" - >/dev/null || fail "could not build the test-hooks image (the post_swap_validated seam moved?)"
    _BUILT_IMAGES+=("$ref")
  fi
  # shellcheck disable=SC2034  # read by tests/updater.sh, which sources this file
  HOOKS_IMAGE="$ref"
}

# keep_names_of <repo> — the sidecar-owned keep names (<repo>:autoupdate-…)
# that exist for <repo>.
keep_names_of() {
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -F "$1:autoupdate-" || true
}

# local_names_intact <tag…> — 0 when every tag, and a keep name for its
# repository, still exist on the daemon. An idle cycle
# must never lose either: without the operator's tag a plain `docker compose
# up -d` pulls whatever the registry serves, unverified; without the keep
# name a rollback has nothing to go back to.
local_names_intact() {
  local t
  for t in "$@"; do
    docker image inspect "$t" >/dev/null 2>&1 || { echo "missing local tag: $t" >&2; return 1; }
    [ -n "$(keep_names_of "${t%:*}")" ] || { echo "missing keep name for ${t%:*}" >&2; return 1; }
  done
}

# compose_up_is_noop <dir> — 0 when the operator's own `docker compose up -d`,
# run in the project directory right now, recreates nothing. After a deploy
# by the sidecar that must hold: a different configuration hash would make
# that routine command (or a configuration-management run) restart DNS.
compose_up_is_noop() {
  local dir="$1" before after proj out
  proj=$(fixture_project "$dir")
  before=$(docker compose -p "$proj" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q | sort)
  out=$( cd "$dir" && docker compose -p "$proj" up -d 2>&1 ) || { printf '%s\n' "$out" >&2; return 1; }
  after=$(docker compose -p "$proj" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q | sort)
  [ -n "$before" ] && [ "$before" = "$after" ] && return 0
  # Say what Compose did and what it compared: a bare "recreated" is not
  # enough to tell an image-identity mismatch from a configuration one.
  {
    echo "--- compose up -d:"; printf '%s\n' "$out"
    echo "--- containers before: $(tr '\n' ' ' <<<"$before")"
    echo "--- containers after:"
    local c img
    for c in $after; do
      img=$(docker inspect "$c" --format '{{.Config.Image}}')
      echo "$c service=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.service"}}')" \
        "declared=$img container.Image=$(docker inspect "$c" --format '{{.Image}}')" \
        "label.image=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.image"}}')" \
        "tag.Id=$(docker image inspect "$img" --format '{{.Id}}' 2>&1)"
    done
    docker version --format 'docker client {{.Client.Version}} server {{.Server.Version}}'
    docker compose version
  } >&2
  return 1
}

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

# fixture_destroy <dir> — removes EVERYTHING a fixture may have left on the
# shared daemon, whatever state the test died in. `compose down` alone is not
# enough: registry_forward attaches the throwaway registry to the project
# network, and Docker refuses to remove a network that still has an endpoint,
# so every registry test used to leak its `<project>_default` network. A
# cycle interrupted mid-way also leaves the sidecar's canary objects and
# possibly a self-update helper behind.
fixture_destroy() {
  local dir="$1" p net c
  p=$(fixture_project "$dir")
  net="${p}_default"
  for c in $(docker ps -aq --filter label=unbound-autoupdate.helper=1 --filter "volume=$dir" 2>/dev/null); do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker rm -f "unbound-canary-$p" >/dev/null 2>&1 || true
  for c in $(docker network inspect "$net" --format '{{range $id, $e := .Containers}}{{$id}} {{end}}' 2>/dev/null); do
    case "$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)" in
      "$p") : ;;
      *) docker network disconnect -f "$net" "$c" >/dev/null 2>&1 || true ;;
    esac
  done
  if [ -f "$dir/docker-compose.yml" ]; then
    docker compose -p "$p" --project-directory "$dir" -f "$dir/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  # Belt and braces for anything `down` could not reach (no compose file left,
  # or a container it could not stop): by project label and by name.
  for c in $(docker ps -aq --filter "label=com.docker.compose.project=$p" 2>/dev/null); do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker network rm "$net" "unbound-canary-net-$p" >/dev/null 2>&1 || true
  docker volume rm "${p}_state" "${p}_ustate" "unbound-canary-vol-$p" >/dev/null 2>&1 || true
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
  docker rm -fv "$REGISTRY_NAME" >/dev/null 2>&1 || true
  # A new registry is a new world: local images named after the previous one
  # (an earlier test's tags, moved by its own cycles) would otherwise stand
  # in for what this test publishes.
  _registry_local_images_rm
  docker run -d --name "$REGISTRY_NAME" -p 127.0.0.1:5000:5000 \
    registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
  # Probed from INSIDE the registry container: the suite may drive a remote
  # daemon (DOCKER_HOST, e.g. a docker:dind used to test the classic image
  # store), where this host's loopback is not the daemon's.
  local _i
  for _i in $(seq 1 30); do
    docker exec "$REGISTRY_NAME" wget -q -O /dev/null "http://127.0.0.1:5000/v2/" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "local registry never became ready"
}

# _registry_local_images_rm — every local image named after the throwaway
# registry. REGISTRY_HOST is this suite's own loopback registry, so nothing
# else lives under that name.
_registry_local_images_rm() {
  docker images --format '{{.Repository}} {{.ID}}' 2>/dev/null \
    | awk -v h="$REGISTRY_HOST/" 'index($1, h) == 1 { print $2 }' | sort -u \
    | while IFS= read -r ref; do docker image rm -f "$ref" >/dev/null 2>&1 || true; done
}

registry_down() { docker rm -fv "$REGISTRY_NAME" >/dev/null 2>&1 || true; }

# registry_publish <dockerfile-text> <repo:tag> — builds and pushes, echoes
# the ref. The repo name must contain "unbound", which discovery requires to
# recognise the target service.
#
# The local build tag is REMOVED after the push. A production host holds an
# image only under the tag it was pulled by, and on the containerd image
# store an image whose only tag moves away can lose its record entirely;
# keeping an extra local tag on every test image hid exactly that class of
# defect. Assertions identify images by their test LABEL (service_label), or
# by registry digest (registry_digest), never by a local tag.
#
# Publishing must not disturb the LOCAL tag either: a fixture may already run
# an image pulled under that very tag, and on a production host the tag is
# not moved by a release happening in the registry. Whatever the tag named
# before is held under a temporary name across the build and push, and put
# back afterwards (on the containerd store, an image whose only name moves
# away can lose its record — the hold is what keeps it).
registry_publish() {
  local ref="$REGISTRY_HOST/$2" hold="$REGISTRY_HOST/upd-hold:$$" had=0
  printf '%s\n' "$ref" >> "$_TRACK_FILE"
  if docker image inspect "$ref" >/dev/null 2>&1; then docker tag "$ref" "$hold" && had=1; fi
  printf '%s\n' "$1" | docker build -q -t "$ref" - >/dev/null
  docker push -q "$ref" >/dev/null
  docker image rm "$ref" >/dev/null 2>&1 || true
  if [ "$had" = 1 ]; then docker tag "$hold" "$ref"; docker image rm "$hold" >/dev/null 2>&1 || true; fi
  printf '%s\n' "$ref"
}

# service_label <dir> <service> <label> — the label as the service's running
# CONTAINER carries it: which image runs, without any image record.
service_label() {
  local cid
  cid=$(fixture_service_cid "$1" "$2")
  [ -n "$cid" ] || { echo ""; return 0; }
  docker inspect "$cid" --format "{{index .Config.Labels \"$3\"}}" 2>/dev/null || echo ""
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

# signed_resolver_fixture <dir> <repo:tag> — a fixture whose RESOLVER image
# lives in the throwaway registry and is signed with the test key. Every image
# a cycle canaries or recreates is now verified — the one already running
# included — so a test that runs cycles in key mode needs a resolver signed
# with that key: the published images are signed keyless, by the release
# pipeline. Sets SIGNED_RESOLVER. FIXTURE_* variables pass through. Needs
# registry_up first.
signed_resolver_fixture() {
  local dir="$1"
  SIGNED_RESOLVER=$(registry_publish "FROM $MOVING_REF
LABEL test.signed_resolver=\"$2\"" "$2")
  fixture_create "$dir" "$SIGNED_RESOLVER"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  registry_sign "$dir" "$SIGNED_RESOLVER"
}

# registry_digest <ref> — repo@sha256 of <ref> as the throwaway registry
# serves it NOW, asked of the registry itself (from inside its container, so
# that it works whichever daemon the suite drives).
registry_digest() {
  local ref="$1" path repo tag d
  path="${ref#"$REGISTRY_HOST"/}"; repo="${path%:*}"; tag="${path##*:}"
  d=$(docker exec "$REGISTRY_NAME" wget -q -S --spider \
        --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "http://127.0.0.1:5000/v2/$repo/manifests/$tag" 2>&1 \
      | awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tr -d '\r' | head -1)
  [ -n "$d" ] && printf '%s@%s\n' "$REGISTRY_HOST/$repo" "$d"
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
  for ref in "${_BUILT_IMAGES[@]:-}"; do
    [ -n "$ref" ] && docker image rm "$ref" >/dev/null 2>&1 || true
  done
  if [ -f "$_TRACK_FILE" ]; then
    sort -u "$_TRACK_FILE" | while IFS= read -r ref; do
      docker image rm "$ref" >/dev/null 2>&1 || true
    done
    rm -f "$_TRACK_FILE"
  fi
  # And every record pulled from the throwaway registry.
  _registry_local_images_rm
  # And what the cycles under test left on the daemon by design: the
  # sidecar-owned <repo>:autoupdate-… keep names and images pulled by
  # digest. Only images that did not exist when the suite started, and only
  # in the repositories this suite deploys, are removed.
  docker images --no-trunc --format '{{.ID}} {{.Repository}} {{.Tag}}' 2>/dev/null \
    | while read -r ref d tag; do
        case "$d" in esitcparis/unbound-*|"$REGISTRY_HOST"/*|"${UPDATER_IMAGE%:*}") : ;; *) continue ;; esac
        if [[ "$tag" == autoupdate-* ]]; then
          case " $_PRE_IMAGE_NAMES " in *" $d:$tag "*) : ;; *) docker image rm "$d:$tag" >/dev/null 2>&1 || true ;; esac
        elif [ "$tag" = "<none>" ]; then
          case " $_PRE_IMAGE_IDS " in *" $ref "*) : ;; *) docker image rm -f "$ref" >/dev/null 2>&1 || true ;; esac
        fi
      done
  registry_down
  exit "$status"
}
# Image IDs present before the suite ran: never touched by the reaper.
_PRE_IMAGE_IDS=$(docker images -q --no-trunc 2>/dev/null | sort -u | tr '\n' ' ')
_PRE_IMAGE_NAMES=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u | tr '\n' ' ')
trap _fixture_reap_leftovers EXIT
# An interrupted run (Ctrl-C, a CI cancellation, a kill) must clean up too:
# turning each signal into an ordinary exit is what makes bash run the EXIT
# trap above instead of dying with the fixtures still up.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
