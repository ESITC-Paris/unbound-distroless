#!/usr/bin/env bash
# Compose discovery. Declared state comes from `docker compose config`;
# running state comes from `docker inspect`. Keeping those two sources
# separate is the whole point: the canary must test what Compose WILL
# deploy, not what happens to be mounted right now.

# discover_self_id — the sidecar's own container id.
discover_self_id() {
  local id
  id=$(grep -oE '/(docker|containers)/[0-9a-f]{64}' /proc/self/mountinfo 2>/dev/null \
       | grep -oE '[0-9a-f]{64}' | head -1) || true
  [ -n "$id" ] || id=$(docker ps --no-trunc --format '{{.ID}}' \
       | grep -m1 "^$(cat /etc/hostname)") || true
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

_label() { docker inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null; }

# _compose_file_args <config-files-label> — turn Compose's
# project.config_files label into this project's -f arguments, in order.
# Split out of discover_target purely so it can be unit-tested directly
# against synthetic label strings: the shapes that matter here (one file, two
# files, a trailing separator, relative paths, the rollback override) are
# cheap to assert in a bare container and would otherwise only ever be
# covered indirectly, by slow integration tests that need a live registry.
# Bug A lived here precisely because nothing asserted the result.
_compose_file_args() {
  local paths f
  # The work is done by _compose_file_paths in a child, so that a caller for
  # which an unreadable file is NOT fatal (self_update, which runs after the
  # resolver's own work is already done and recorded) can reuse the exact same
  # parsing and exclusions. Here, as before, any failure ends the cycle; the
  # child has already said why.
  paths=$(_compose_file_paths "$1") || exit 1
  COMPOSE_FILE_ARGS=()
  while IFS= read -r f; do
    [ -n "$f" ] && COMPOSE_FILE_ARGS+=(-f "$f")
  done <<<"$paths"
}

# _compose_file_paths <config-files-label> — the label's files, resolved and
# filtered, one per line; non-zero (with the reason logged) when one of them
# cannot be read from inside the sidecar.
_compose_file_paths() {
  local files="$1" f
  # A hard failure, not a "${ROLLBACK_FILE:-}" fallback. If this is ever empty
  # — state.sh sourced after this file, or STATE_DIR differing between cycles
  # — the comparison below silently matches nothing and the rollback override
  # walks straight back into the project definition, which is Bug B returning
  # with no error at all. That class of regression has to be loud.
  [ -n "${ROLLBACK_FILE:-}" ] || log_die "internal error: ROLLBACK_FILE is unset — state.sh must be sourced before discover.sh"

  # The trailing newline fed to this loop is load-bearing: `read` returns
  # false on a final field that is not newline-terminated, so with a bare
  # `printf '%s'` the body never ran at all and COMPOSE_FILE_ARGS stayed
  # EMPTY for the usual single-file project. Every other call papered over
  # that, because Compose then discovers docker-compose.yml from
  # --project-directory on its own — but the rollback adds a second -f, and
  # with no base file in the list the override became the ONLY compose file.
  # Production was then recreated from a service definition consisting of
  # nothing but `image:`: no state volume (losing the DNSSEC trust anchor),
  # no bind-mounted unbound.conf (silently falling back to the image's
  # built-in defaults), no cap_drop and no no-new-privileges — while the
  # cycle still reported "rollback successful".
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Compose records relative paths when invoked with one; resolve against workdir.
    case "$f" in /*) : ;; *) f="$COMPOSE_WORKDIR/$f" ;; esac
    # The updater's own rollback override is a transient artefact of ONE
    # cycle, never part of the operator's project. Compose stamps the file
    # list it was invoked with onto the container it creates, so the override
    # used for a rollback comes back on the NEXT cycle's label — and re-pins
    # the declared image to the digest that was rolled back to. The updater
    # would then compare that pin against itself, report "up to date" on
    # every subsequent cycle, and never update again or even reach the
    # quarantine check: a silently frozen updater, green forever.
    case "$f" in
      "$ROLLBACK_FILE"|"${SELF_ROLLBACK_FILE:-}") continue ;;
    esac
    if [ ! -r "$f" ]; then
      log_error "compose file '$f' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path"
      return 1
    fi
    printf '%s\n' "$f"
  done < <(printf '%s\n' "$files" | tr ',' '\n')
}

# _is_digest_ref <ref> — 0 when <ref> is repository@sha256:<64 hex>, the only
# shape this sidecar ever writes into a Compose override or hands to `docker
# run`. The value comes from image metadata; checking its shape before it is
# interpolated into YAML is what keeps a malformed one from becoming anything
# other than an image reference.
_is_digest_ref() {
  [[ "$1" =~ ^[][A-Za-z0-9][][A-Za-z0-9._/:-]*@sha256:[0-9a-f]{64}$ ]]
}

# write_pin_file <file> <ref> <service…> — a Compose override that pins every
# named service to <ref>: a digest reference, or a sidecar-owned keep name
# (keep_name). Used only by the rollbacks of a service
# whose compose file declares a DIGEST (or another repository than the one
# being restored), where moving the operator's tag cannot express the
# previous image; every other deployment moves the tag (tag_for_deploy).
write_pin_file() {
  local file="$1" ref="$2" s; shift 2
  if ! _is_digest_ref "$ref" && ! [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*:autoupdate-[A-Za-z0-9_.-]+$ ]]; then
    log_error "refusing to pin '$ref': neither a repository@sha256 digest reference nor an autoupdate keep name"; return 1
  fi
  {
    printf 'services:\n'
    for s in "$@"; do printf '  %s:\n    image: "%s"\n' "$s" "$ref"; done
  } > "$file"
}

# _image_repo <ref> — the repository part of an image reference: no tag, no
# digest. "127.0.0.1:5000/unbound-x:1" and "127.0.0.1:5000/unbound-x@sha256:…"
# both give "127.0.0.1:5000/unbound-x". The registry port is not a tag: only
# the LAST path component is inspected for a colon.
_image_repo() {
  local ref="${1%%@*}" last
  last="${ref##*/}"
  case "$last" in *:*) ref="${ref%:*}" ;; esac
  printf '%s\n' "$ref"
}

# discover_target_container — SELF_* and the target container, from labels
# only. Enough for the metrics CGI, which must not need the compose project
# files; discover_target builds on it.
discover_target_container() {
  SELF_ID=$(discover_self_id) || log_die "cannot determine my own container id — is /var/run/docker.sock mounted?"
  # Produced for callers (target_probe_ip's network_mode: host check, and
  # later tasks); shellcheck cannot see that use from this file alone.
  # shellcheck disable=SC2034
  SELF_IMAGE=$(docker inspect "$SELF_ID" --format '{{.Config.Image}}')
  # shellcheck disable=SC2034
  SELF_IMAGE_ID=$(docker inspect "$SELF_ID" --format '{{.Image}}')

  COMPOSE_PROJECT=$(_label "$SELF_ID" com.docker.compose.project)
  [ -n "$COMPOSE_PROJECT" ] || log_die "this container is not managed by docker compose"

  # Candidate = sibling service in the same project whose image repository
  # mentions unbound. Deliberately loose so forks and private mirrors work.
  # A sibling running the sidecar's OWN image (the metrics service, a second
  # updater) is never the resolver, whatever its repository name contains —
  # and "unbound-autoupdate" does contain "unbound".
  # A resolver that is BEING RECREATED — the seconds between `docker compose
  # up` removing the old container and starting the new one — is simply
  # absent from `docker ps`. A cycle that happens to start in that window
  # used to die, and the EXIT trap recorded it as a FAILED UPDATE: a false
  # "update impossible" page for what is a normal restart. Observed in
  # production on 2026-09-21, one host out of three, purely on timing.
  #
  # So discovery is patient: DISCOVER_WAIT seconds, polled every 2 s. The
  # update cycle sets it; the metrics scrape leaves it at 0 and keeps the
  # old fail-fast behaviour, because a scrape must never block. Two or more
  # candidates is a configuration mistake, not a race — that one still dies
  # immediately, waiting would not change the answer.
  local candidates=() services=() cid img svc self_repo deadline ps_all=()
  # DISCOVER_ALL=1 (set by a cycle recovering an interrupted swap) also
  # accepts containers that exist but do not run. A `compose up` killed
  # mid-recreate leaves TWO containers of the one service — the old one
  # Exited, the new one Created under a temporary name — so candidates are
  # counted by SERVICE, not by container, and the container chosen is the
  # running one if any, else the most recently created.
  [ "${DISCOVER_ALL:-0}" = 1 ] && ps_all=(-a)
  self_repo=$(_image_repo "$SELF_IMAGE")
  deadline=$(( $(date +%s) + ${DISCOVER_WAIT:-0} ))
  TARGET_CONTAINER=""
  while true; do
    candidates=(); services=()
    while read -r cid; do
      [ "$cid" = "$SELF_ID" ] && continue
      img=$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null) || continue
      [ "$(_image_repo "$img")" = "$self_repo" ] && continue
      case "$img" in
        *unbound*)
          candidates+=("$cid")
          svc=$(_label "$cid" com.docker.compose.service)
          case " ${services[*]:-} " in *" $svc "*) : ;; *) services+=("$svc") ;; esac ;;
      esac
    done < <(docker ps "${ps_all[@]}" --no-trunc --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{.ID}}')

    svc="${TARGET_SERVICE:-}"
    [ -z "$svc" ] && [ "${#services[@]}" -eq 1 ] && svc="${services[0]}"
    if [ -n "$svc" ]; then
      TARGET_CONTAINER=$(_service_container "$svc" "${ps_all[@]}")
    elif [ "${#services[@]}" -gt 1 ]; then
      break
    fi

    [ -n "$TARGET_CONTAINER" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || break
    log_info "resolver not running yet — waiting for it to come back"
    sleep 2
  done

  if [ -z "$TARGET_CONTAINER" ]; then
    if [ -n "${TARGET_SERVICE:-}" ]; then
      log_die "TARGET_SERVICE='$TARGET_SERVICE' not found in project '$COMPOSE_PROJECT'"
    fi
    log_die "discovery found ${#services[@]} candidate services (${services[*]:-none}) — set TARGET_SERVICE explicitly"
  fi

  TARGET_SERVICE=$(_label "$TARGET_CONTAINER" com.docker.compose.service)
}

# _service_container <service> [-a] — the service's container in this
# project: the running one if any; with -a, otherwise the most recently
# created (`docker ps` lists newest first).
_service_container() {
  local svc="$1"; shift
  local id
  id=$(docker ps --no-trunc --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
        --filter "label=com.docker.compose.service=$svc" --format '{{.ID}}' | head -1)
  if [ -z "$id" ] && [ "${1:-}" = -a ]; then
    id=$(docker ps -a --no-trunc --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
          --filter "label=com.docker.compose.service=$svc" --format '{{.ID}}' | head -1)
  fi
  printf '%s\n' "$id"
}

# ── Image identity ──────────────────────────────────────────────────────────
#
# The invariant everything below serves: the operator's LOCAL TAG is moved
# only at swap time, to an image that has been verified AND canaried, and on
# every exit after that it names the image that is running. Before the swap
# the cycle works on digests only: the declared tag is resolved to a registry
# digest WITHOUT pulling it (resolve_registry_digest), that digest is pulled
# by digest — which moves no tag — and verified, preflighted and canaried as
# such. Whatever the cycle refuses or fails on, `docker compose up -d` typed
# by the operator next still resolves the tag to what runs.
#
# "The image currently running" is always the running CONTAINER's image ID
# (.Image), never a tag and never RepoDigests: once a tag has moved away from
# an image, the image record may have an empty RepoDigests list or, on some
# containerd-store daemons, vanish entirely while the container keeps
# running it. Two things make that safe:
#   * comparisons are by image ID (on the containerd store the ID is the
#     digest that was pulled; on the classic store it is the config digest —
#     either way equal IDs mean the same image);
#   * keep_running gives the running image a sidecar-owned local name,
#     <repo>:autoupdate-<project>-<service>, so its record survives any
#     tag move and a rollback never needs the registry.

# keep_name <repo> <project> <service> — the sidecar-owned local name that
# keeps a running image's record alive: <repo>:autoupdate-<project>-<service>.
# Per project AND service, so two resolvers from the same repository on one
# host (two Compose projects) never move each other's rollback target.
# Tag grammar: [A-Za-z0-9_.-], at most 128 characters.
keep_name() {
  local t
  t="autoupdate-$2-$3"
  t=$(printf '%s' "$t" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-128)
  printf '%s:%s\n' "$1" "$t"
}

# image_id_of <ref-or-id> — the local image ID, or nothing.
image_id_of() { docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true; }

# container_version <container> — the org.opencontainers.image.version label
# as the CONTAINER carries it (a container's labels include its image's).
# Unlike the image record, the container is always there to ask.
container_version() {
  docker inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}

# familiar_repo <repo> — the repository as Docker itself prints it in
# RepoDigests: no "docker.io/" or "index.docker.io/" prefix, no "library/"
# for official images. A compose file may write either; digests, quarantine
# entries and messages must not depend on which.
familiar_repo() {
  local r="$1"
  r="${r#docker.io/}"; r="${r#index.docker.io/}"; r="${r#registry-1.docker.io/}"
  r="${r#library/}"
  printf '%s\n' "$r"
}

# _valid_ref <ref> — the reference grammar this sidecar accepts before it
# puts a reference into a URL or a command: name components, an optional
# port, a tag or a digest. Nothing a URL could interpret (%, ?, #, spaces).
_valid_ref() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; }

# _registry_host <ref> — the registry a reference names, as config.json keys it.
_registry_host() {
  local first="${1%%/*}"
  case "$1" in */*) : ;; *) first="" ;; esac
  case "$first" in
    *.*|*:*|localhost) [ "$first" = docker.io ] || [ "$first" = index.docker.io ] && { printf '%s\n' "https://index.docker.io/v1/"; return 0; }
                       printf '%s\n' "$first" ;;
    *) printf '%s\n' "https://index.docker.io/v1/" ;;
  esac
}

# _registry_basic <ref> — "user:password" for <ref>'s registry from the same
# Docker client configuration `docker pull` in this container would use
# (DOCKER_CONFIG, default ~/.docker). Static `auths` entries only: a
# credential helper is a binary this image does not carry, for `docker pull`
# as much as for this. Empty when there is nothing.
_registry_basic() {
  local cfg="${DOCKER_CONFIG:-${HOME:-/root}/.docker}/config.json" auth
  [ -r "$cfg" ] || return 0
  auth=$(jq -r --arg h "$(_registry_host "$1")" '.auths[$h].auth // empty' "$cfg" 2>/dev/null) || return 0
  [ -n "$auth" ] || return 0
  printf '%s' "$auth" | base64 -d 2>/dev/null || true
}

# _registry_auth_header <ref> — the same credentials as an X-Registry-Auth
# header value for the Engine API.
_registry_auth_header() {
  local up host
  up=$(_registry_basic "$1"); [ -n "$up" ] || return 0
  host=$(_registry_host "$1")
  jq -nc --arg u "${up%%:*}" --arg p "${up#*:}" --arg h "$host" '{username:$u, password:$p, serveraddress:$h}' \
    | base64 | tr -d '\n' | tr '+/' '-_'
}

_MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# _head_digest <ref> — the digest a tag names, from ONE registry HEAD request
# (plus a token request when the registry asks for one). Docker Hub counts a
# manifest GET as a pull and does not count a HEAD; every hourly cycle asks
# about two references (resolver and sidecar), so a fleet behind one NAT
# would otherwise spend its anonymous pull allowance on cycles that pull
# nothing. Speaks the registry token protocol itself (Bearer realm/service/
# scope from WWW-Authenticate, Basic with static credentials). Plain HTTP is
# tried only for loopback registries, as Docker itself does. Non-zero when
# this cannot work here (custom CA, mirror-only network, proxy rules): the
# caller then asks the daemon.
_head_digest() {
  local ref="$1" repo tag host path url scheme hdrs wa realm service scope tok up auth=()
  repo=$(_image_repo "$ref"); tag="${ref#"$repo":}"
  [ "$tag" != "$ref" ] || tag=latest
  host="${repo%%/*}"; path="${repo#*/}"
  case "$repo" in */*) : ;; *) host="" ;; esac
  case "$host" in
    *.*|*:*|localhost) : ;;
    *) host=""; path="$repo" ;;
  esac
  case "$host" in ""|docker.io|index.docker.io) host=registry-1.docker.io
    case "$path" in */*) : ;; *) path="library/$path" ;; esac ;;
  esac
  for scheme in https http; do
    if [ "$scheme" = http ]; then
      case "$host" in localhost|localhost:*|127.*) : ;; *) return 1 ;; esac
    fi
    url="$scheme://$host/v2/$path/manifests/$tag"
    hdrs=$(curl -sS -I -m 30 --proto '=https,http' -H "Accept: $_MANIFEST_ACCEPT" "$url" 2>/dev/null) || continue
    if grep -qiE '^HTTP/[0-9.]+ 401' <<<"$hdrs"; then
      wa=$(grep -i '^www-authenticate:' <<<"$hdrs" | tr -d '\r' | head -1)
      up=$(_registry_basic "$ref")
      case "$wa" in
        *[Bb]earer*)
          realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$wa")
          service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$wa")
          scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$wa")
          [ -n "$scope" ] || scope="repository:$path:pull"
          [ -n "$realm" ] || return 1
          if [ -n "$up" ]; then
            tok=$(curl -fsS -m 30 --proto '=https' -u "$up" -G --data-urlencode "service=$service" --data-urlencode "scope=$scope" "$realm" 2>/dev/null) || return 1
          else
            tok=$(curl -fsS -m 30 --proto '=https' -G --data-urlencode "service=$service" --data-urlencode "scope=$scope" "$realm" 2>/dev/null) || return 1
          fi
          tok=$(jq -r '.token // .access_token // empty' <<<"$tok" 2>/dev/null)
          [ -n "$tok" ] || return 1
          auth=(-H "Authorization: Bearer $tok") ;;
        *[Bb]asic*) [ -n "$up" ] || return 1; auth=(-u "$up") ;;
        *) return 1 ;;
      esac
      hdrs=$(curl -sS -I -m 30 --proto '=https,http' "${auth[@]}" -H "Accept: $_MANIFEST_ACCEPT" "$url" 2>/dev/null) || return 1
    fi
    grep -qiE '^HTTP/[0-9.]+ 200' <<<"$hdrs" || return 1
    grep -i '^docker-content-digest:' <<<"$hdrs" | awk '{print $2}' | tr -d '\r' | grep -E '^sha256:[0-9a-f]{64}$' | head -1
    return 0
  done
  return 1
}

# resolve_registry_digest <ref> — repo@sha256:… that <ref> names in its
# registry RIGHT NOW, without pulling and without moving any local tag. A
# digest reference resolves to itself. One HEAD request to the registry
# (_head_digest); where that cannot work from this container, the Docker
# daemon is asked instead (Engine API GET /distribution/<ref>/json), with the
# daemon's own registry configuration (mirrors, insecure registries, CA
# certificates, proxy) — at the price of a manifest GET. The repository is
# returned in Docker's familiar spelling (familiar_repo).
resolve_registry_digest() {
  local ref="$1" out hdr digest
  _valid_ref "$ref" || { log_error "refusing to resolve '$ref': not a valid image reference"; return 1; }
  case "$ref" in *@sha256:*) printf '%s@%s\n' "$(familiar_repo "$(_image_repo "$ref")")" "${ref##*@}"; return 0 ;; esac
  if ! digest=$(_head_digest "$ref") || [ -z "$digest" ]; then
    hdr=$(_registry_auth_header "$ref")
    if [ -n "$hdr" ]; then
      out=$(curl -fsS -m 60 --unix-socket /var/run/docker.sock -H "X-Registry-Auth: $hdr" \
            "http://localhost/distribution/$ref/json" 2>&1) || { log_error "cannot resolve $ref in its registry: $out"; return 1; }
    else
      out=$(curl -fsS -m 60 --unix-socket /var/run/docker.sock \
            "http://localhost/distribution/$ref/json" 2>&1) || { log_error "cannot resolve $ref in its registry: $out"; return 1; }
    fi
    digest=$(jq -r '.Descriptor.digest // empty' <<<"$out" 2>/dev/null) || digest=""
  fi
  case "$digest" in sha256:*) : ;; *) log_error "the registry returned no digest for $ref"; return 1 ;; esac
  printf '%s@%s\n' "$(familiar_repo "$(_image_repo "$ref")")" "$digest"
}

# pull_by_digest <repo@sha256:…> — make an image present locally by digest:
# content arrives, no tag moves. Nothing is pulled when the image is already
# here under any name (the hourly up-to-date cycle pulls nothing: the
# declared digest IS the running image). Only a reference this sidecar
# actually pulled is remembered (state PULLED_REFS), for prune_pulled.
pull_by_digest() {
  local ref="$1" out prev
  _is_digest_ref "$ref" || { log_error "refusing to pull '$ref': not a repository@sha256 digest reference"; return 1; }
  [ -z "$(image_id_of "$ref")" ] || return 0
  out=$(docker pull -q "$ref" 2>&1) || { log_error "pulling $ref failed"; printf '%s\n' "$out" >&2; return 1; }
  prev=$(state_get PULLED_REFS)
  case " $prev " in *" $ref "*) : ;; *) state_set PULLED_REFS "${prev:+$prev }$ref" ;; esac
}

# prune_pulled <ref-to-keep…> — remove what this sidecar pulled by digest and
# no longer needs: a refused or superseded image, so they do not pile up.
#
# `docker image rm <repo>@<digest>` does not mean the same on both stores: on
# the classic store it drops that digest reference only; on the containerd
# store it removes EVERY name of that image in the repository — the
# operator's tag and the keep name (keep_name) included (measured on
# Engine 29). So a reference is removed only while NO tag names its image
# (a containerd digest-only record lists its digest among RepoTags; only
# real tags count) and the image is none of PRUNE_PROTECT_IDS (what runs,
# what is being deployed). Otherwise it stays on the list, and goes once the
# tags have moved away from it. `rm` without -f also refuses an image a
# container uses.
prune_pulled() {
  local keep=" $* " r id tags left=""
  for r in $(state_get PULLED_REFS); do
    case "$keep" in *" $r "*) left="${left:+$left }$r"; continue ;; esac
    id=$(image_id_of "$r")
    [ -n "$id" ] || continue
    tags=$(docker image inspect "$r" --format '{{range .RepoTags}}{{println .}}{{end}}' 2>/dev/null | grep -v '@' || true)
    if [ -n "$tags" ] || [[ " ${PRUNE_PROTECT_IDS:-} " == *" $id "* ]]; then
      left="${left:+$left }$r"; continue
    fi
    docker image rm "$r" >/dev/null 2>&1 || left="${left:+$left }$r"
  done
  state_set PULLED_REFS "$left"
}

# keep_running <keep-name> <image-id> — <keep-name> (keep_name) names the
# image a service runs, so that its record survives any move of the
# operator's tag (the rollback target, the version and labels of what runs).
# Best effort: false, with the reason logged, when the record is already
# gone — then only the registry can bring the image back.
keep_running() {
  local name="$1" id="$2"
  [ -n "$id" ] || return 1
  [ "$(image_id_of "$name")" = "$id" ] && return 0
  docker tag "$id" "$name" >/dev/null 2>&1 && return 0
  log_warn "the running image $id has no local record any more (its tag was moved and the image store dropped it) — a rollback would need the registry"
  return 1
}

# tag_for_deploy <tag> <image-ref-or-id> — move the operator's tag onto the
# image to deploy. Called at swap or rollback time only, and only for a tag:
# a digest-declared service is deployed as written.
tag_for_deploy() {
  case "$1" in *@*) return 0 ;; esac
  docker tag "$2" "$1" >/dev/null 2>&1 || { log_error "cannot point local tag $1 at $2"; return 1; }
}

# describe_image <image-id> <repo> — a human-readable name for an image ID:
# its digest in <repo> when the record still lists one, the ID otherwise.
describe_image() {
  local d
  d=$(_digest_for_repo "$2" "$(_repo_digests "$1" || true)") \
    || d=$(_repo_digests "$1" 2>/dev/null | head -1) || d=""
  printf '%s\n' "${d:-$1}"
}

discover_target() {
  discover_target_container

  COMPOSE_WORKDIR=$(_label "$TARGET_CONTAINER" com.docker.compose.project.working_dir)
  local files; files=$(_label "$TARGET_CONTAINER" com.docker.compose.project.config_files)
  [ -n "$files" ] && [ -n "$COMPOSE_WORKDIR" ] || log_die "target container carries no compose file labels"

  _compose_file_args "$files"

  _read_declared
  _read_running_mounts
}

# compose <args…> — always scoped to the discovered project.
compose() {
  local args=(-p "$COMPOSE_PROJECT" --project-directory "$COMPOSE_WORKDIR" "${COMPOSE_FILE_ARGS[@]}")
  [ -n "${COMPOSE_EXTRA_FILE:-}" ] && args+=(-f "$COMPOSE_EXTRA_FILE")
  docker compose "${args[@]}" "$@"
}

# _read_declared — DECLARED_IMAGE_REF and DECLARED_BIND_MOUNTS, from the
# compose project itself rather than from the running container.
_read_declared() {
  local cfg
  cfg=$(compose config --format json) || log_die "docker compose config failed — the project cannot be resolved from inside the sidecar"

  DECLARED_IMAGE_REF=$(jq -r --arg s "$TARGET_SERVICE" '.services[$s].image // empty' <<<"$cfg")
  [ -n "$DECLARED_IMAGE_REF" ] || log_die "service '$TARGET_SERVICE' declares no image"

  # Every declared bind mount, not just ones under /etc/unbound: production
  # may mount a cert, a zonefile, or anything else elsewhere, and the canary
  # must run with the SAME filesystem view or it validates a configuration
  # production doesn't actually have. /var/lib/unbound is excluded because
  # that's the state volume, which is cloned separately, not bind-mounted.
  DECLARED_BIND_MOUNTS=()
  local src dst
  while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] || continue
    [ -r "$src" ] || log_die "declared bind mount '$src' is not readable from inside the sidecar — it must be mounted read-only at the same absolute path"
    DECLARED_BIND_MOUNTS+=(-v "$src:$dst:ro")
  done < <(jq -r --arg s "$TARGET_SERVICE" '
      .services[$s].volumes // []
      | .[] | select(.type == "bind")
      | select(.target | startswith("/var/lib/unbound") | not)
      | [.source, .target] | @tsv' <<<"$cfg")

  _read_declared_runtime "$cfg"
}

# _read_declared_runtime <compose-config-json> — DECLARED_RUNTIME_ARGS, the
# `docker run` flags that make the canary run under the same runtime settings
# Compose will give production: read_only, tmpfs, environment, ulimits and
# sysctls. Image, state and bind mounts alone are not enough: a canary with
# a writable rootfs and no tmpfs can pass while a production declared
# read-only fails at the first write, or the reverse. Capabilities and
# security_opt are NOT taken from the declaration — the canary always runs
# with the hardened set the image is tested with.
_read_declared_runtime() {
  local cfg="$1" item
  DECLARED_RUNTIME_ARGS=()

  if [ "$(jq -r --arg s "$TARGET_SERVICE" '.services[$s].read_only // false' <<<"$cfg")" = true ]; then
    DECLARED_RUNTIME_ARGS+=(--read-only)
  fi

  # tmpfs: a list of "path" or "path:options" (a bare string is also legal).
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    DECLARED_RUNTIME_ARGS+=(--tmpfs "$item")
  done < <(jq -r --arg s "$TARGET_SERVICE" '
      .services[$s].tmpfs // [] | if type == "string" then [.] else . end | .[]' <<<"$cfg")

  # environment: Compose normalises it to a map; a null value means "take it
  # from the invoking environment", which `-e KEY` reproduces. Each entry is
  # base64-encoded on its own line because a value may contain anything,
  # including newlines — and jq (1.8) silently drops a NUL byte from raw
  # output, so NUL-delimiting is not an option here.
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    DECLARED_RUNTIME_ARGS+=(-e "$(printf '%s' "$item" | base64 -d)")
  done < <(jq -r --arg s "$TARGET_SERVICE" '
      .services[$s].environment // {} | to_entries[]
      | (if .value == null then .key else "\(.key)=\(.value)" end) | @base64' <<<"$cfg")

  # ulimits: either a single number or {soft, hard}.
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    DECLARED_RUNTIME_ARGS+=(--ulimit "$item")
  done < <(jq -r --arg s "$TARGET_SERVICE" '
      .services[$s].ulimits // {} | to_entries[]
      | if (.value | type) == "object" then "\(.key)=\(.value.soft):\(.value.hard)" else "\(.key)=\(.value)" end' <<<"$cfg")

  # sysctls: a map after normalisation, but accept the list form too.
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    DECLARED_RUNTIME_ARGS+=(--sysctl "$item")
  done < <(jq -r --arg s "$TARGET_SERVICE" '
      .services[$s].sysctls // {}
      | if type == "array" then .[] else to_entries[] | "\(.key)=\(.value)" end' <<<"$cfg")
}

_read_running_mounts() {
  TARGET_STATE_VOLUME=$(docker inspect "$TARGET_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/unbound"}}{{.Name}}{{end}}{{end}}')
  [ -n "$TARGET_STATE_VOLUME" ] || log_die "service '$TARGET_SERVICE' has no named volume on /var/lib/unbound — required to persist the DNSSEC trust anchor and to clone state for the canary"
}

# _repo_digests <image-ref-or-id> — the image record's RepoDigests, one per
# line. Exits non-zero when there is no such image record at all, which is a
# different thing from a record that carries no repository digest.
_repo_digests() {
  docker image inspect "$1" --format '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' 2>/dev/null
}

# _digest_for_repo <repo> <digest-list> — the entry of <digest-list> whose
# repository is <repo>; non-zero when there is none.
#
# ONE image record can carry SEVERAL repository digests: the same bits pulled
# from one repository and pushed to another (a mirror, a staging copy, a test
# registry) are a single local image, and every push adds an entry to it.
# `index .RepoDigests 0` then returns whichever repository happens to be
# listed first — which need not be the one the compose file declares. What
# must be compared against what is running, and handed to cosign, is the
# digest of the DECLARED repository: a signature lives in the repository it
# was made in, and a digest from a different repository is not a statement
# about the image this project deploys.
_digest_for_repo() {
  local repo="$1" e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [ "$(_image_repo "$e")" = "$repo" ]; then printf '%s\n' "$e"; return 0; fi
  done <<<"$2"
  return 1
}

# config_fingerprint — one sha256 over every declared bind mount, ordered.
# Covering all of them (not just unbound.conf) is intended: a rotated
# certificate or any other bind-mounted file changing must trigger a canary
# and a redeploy just as surely as an edited unbound.conf does.
#
# A declared mount may be a DIRECTORY (the shipped unbound.conf's DoT example
# mounts a whole tls/ directory), so every mount is expanded to the regular
# files beneath it. Each file contributes its content hash AND its path
# relative to the mount, so a rename inside the directory changes the
# fingerprint too: a certificate unbound.conf can no longer find under its
# old name is just as much a change as new bytes in it.
#
# Any failure (an unreadable file, a path that vanished between discovery
# and here) makes the function return non-zero. It must never hash whatever
# happened to be readable and present that as the fingerprint of the whole
# configuration: a silently partial hash is precisely the kind of quiet
# wrongness this project exists to remove.
config_fingerprint() {
  local src dst spec rest paths=() ex skip
  local i
  for (( i = 0; i < ${#DECLARED_BIND_MOUNTS[@]}; i++ )); do
    [ "${DECLARED_BIND_MOUNTS[$i]}" = "-v" ] || continue
    spec="${DECLARED_BIND_MOUNTS[$((i+1))]}"
    src="${spec%%:*}"; rest="${spec#*:}"; dst="${rest%%:*}"
    # FINGERPRINT_EXCLUDE: container paths (space-separated) whose content is
    # DATA managed by another tool, not configuration. The canonical case is a
    # blocklist regenerated nightly and applied to the running resolver at
    # runtime (unbound-control local_zones): fingerprinting it made every
    # regeneration a canary + container swap, which restarts unbound and
    # empties its cache for a change that needed neither.
    #
    # Excluding a path removes it from CHANGE DETECTION only. The mount is
    # still passed to the canary (DECLARED_BIND_MOUNTS is untouched), so an
    # image update is still validated against the real data. The tool that
    # owns the excluded data is responsible for validating it before use.
    # An exclusion is the operator's explicit decision, never a default.
    skip=0
    for ex in ${FINGERPRINT_EXCLUDE:-}; do
      ex="${ex%/}"
      if [ "$dst" = "$ex" ] || [ "${dst#"$ex"/}" != "$dst" ]; then skip=1; break; fi
    done
    [ "$skip" = 1 ] && continue
    paths+=("$src")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    printf '' | sha256sum | cut -d' ' -f1
    return 0
  fi
  # NUL-delimited throughout: a declared path may contain spaces (a compose
  # project can live anywhere on the host), and `sort`/`xargs`'s default
  # whitespace splitting would silently hash the wrong files instead of
  # failing loudly. The subshell sets pipefail on its own so the verdict does
  # not depend on the caller's shell options.
  (
    set -o pipefail
    local out
    for src in "${paths[@]}"; do
      if [ -d "$src" ]; then
        # Relative names, so the same directory hashes the same wherever the
        # project lives on the host; sorted, so order is deterministic.
        #
        # -L, and -type l alongside -type f, are both load-bearing. A tls/
        # directory in the Let's Encrypt `live/` layout contains nothing but
        # SYMLINKS, and `find . -type f` skips every one of them: the mount
        # would expand to no files at all and a renewed certificate would
        # never change the fingerprint — silently, which is the exact case
        # this expansion promises to catch. With -L a symlink to a file is a
        # file; what stays `-type l` is a link that resolves to nothing, and
        # keeping those makes sha256sum fail on them instead of dropping
        # them. A symlink loop makes find itself fail. Both are loud, as
        # they must be: a configuration the sidecar cannot read whole is not
        # a configuration it may hash partially.
        out=$( cd "$src" && find -L . \( -type f -o -type l \) -print0 | sort -z \
            | xargs -0 -r sha256sum ) || exit 1
        # An empty expansion is not "nothing changed", it is "this mount
        # contributes nothing to the fingerprint" — and a mount that can
        # never move the hash is a configuration change this sidecar would
        # never canary. Loud, like every other hole in the coverage.
        [ -n "$out" ] || { log_error "config fingerprint: directory mount '$src' expands to no files"; exit 1; }
        printf '%s\n' "$out"
      elif [ -f "$src" ]; then
        sha256sum < "$src" || exit 1
      else
        log_error "config fingerprint: '$src' is neither a file nor a directory"
        exit 1
      fi
    done | sha256sum | cut -d' ' -f1
  )
}

# major_bump <old-version> <new-version> — 0 when the move must be refused as
# a major bump, with MAJOR_REASON set for the message. The major is the
# leading number of the label (an optional "v" allowed): "1.26.2" → 1,
# "v2.0.0-rc1" → 2. Decisions:
#   both numeric, different majors      → refuse (a major bump);
#   running numeric, new not numeric    → refuse: a release line cannot be
#                                         shown to continue, and a guard that
#                                         gave way on garbage is no guard;
#   running not numeric (a dev or local build, "docs-local"), or a label
#   missing on either side              → allow: there is no release line to
#                                         protect. Two non-numeric labels
#                                         ("docs-local" → "docs-local-2")
#                                         are never a "major bump". Never
#                                         silently: MAJOR_NOTE says why the
#                                         guard did not apply, and the
#                                         callers log it as a warning.
# MAJOR_REASON and MAJOR_NOTE are read by the callers; shellcheck cannot see
# that from here.
# shellcheck disable=SC2034
major_bump() {
  local o n om nm
  MAJOR_REASON=""; MAJOR_NOTE=""
  o="${1#v}"; n="${2#v}"
  if [ -z "$1" ] || [ -z "$2" ]; then
    MAJOR_NOTE="one of the images carries no version label — major-version guard skipped"; return 1
  fi
  om=$(printf '%s' "$o" | grep -oE '^[0-9]+' || true)
  nm=$(printf '%s' "$n" | grep -oE '^[0-9]+' || true)
  if [ -z "$om" ]; then
    MAJOR_NOTE="the running version label '$1' carries no version number — major-version guard skipped"; return 1
  fi
  if [ -z "$nm" ]; then MAJOR_REASON="the new version label '$2' carries no version number"; return 0; fi
  if [ "$((10#$om))" != "$((10#$nm))" ]; then MAJOR_REASON="major version bump $1 -> $2"; return 0; fi
  return 1
}

# version_downgrade <running-version> <new-version> — 0 when the new image is
# an OLDER release than the running one. Versions are X.Y.Z with an optional
# -rN revision. Resolver images up to 1.26.2-r4 carry X.Y.Z only: against
# such a label the revision is not compared, so a revision downgrade is only
# detected between two images that both carry -rN. A label that
# does not parse on either side cannot be compared: allowed, never silently
# — DOWNGRADE_NOTE says why, and the callers log it. Refusing there would
# strand every host whose images carry no usable label.
# DOWNGRADE_NOTE is read by the callers; shellcheck cannot see that here.
# shellcheck disable=SC2034
version_downgrade() {
  local re='^v?([0-9]+)\.([0-9]+)\.([0-9]+)(-r([0-9]+))?$' o=() n=() i
  DOWNGRADE_NOTE=""
  if ! [[ "$1" =~ $re ]]; then
    [ -z "$1" ] || DOWNGRADE_NOTE="the running version label '$1' is not X.Y.Z[-rN] — downgrade guard skipped"
    return 1
  fi
  o=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}")
  if ! [[ "$2" =~ $re ]]; then
    DOWNGRADE_NOTE="the new version label '$2' is not X.Y.Z[-rN] — downgrade guard skipped"
    return 1
  fi
  n=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}")
  for i in 0 1 2 3; do
    [ -n "${o[$i]}" ] && [ -n "${n[$i]}" ] || return 1
    [ "$((10#${n[$i]}))" -lt "$((10#${o[$i]}))" ] && return 0
    [ "$((10#${n[$i]}))" -gt "$((10#${o[$i]}))" ] && return 1
  done
  return 1
}

image_version_label() {
  docker image inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}

# target_probe_ip — the address to send validation queries to.
target_probe_ip() {
  local mode ip
  mode=$(docker inspect "$TARGET_CONTAINER" --format '{{.HostConfig.NetworkMode}}')
  if [ "$mode" = host ]; then
    [ "$(docker inspect "$SELF_ID" --format '{{.HostConfig.NetworkMode}}')" = host ] \
      || log_die "the resolver uses network_mode: host — the updater must declare network_mode: host as well so it can reach it"
    printf '127.0.0.1\n'; return 0
  fi
  ip=$(docker inspect "$TARGET_CONTAINER" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | awk '{print $1}')
  [ -n "$ip" ] || log_die "cannot determine the resolver's container IP"
  printf '%s\n' "$ip"
}
