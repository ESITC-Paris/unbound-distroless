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

discover_target() {
  SELF_ID=$(discover_self_id) || log_die "cannot determine my own container id — is /var/run/docker.sock mounted?"
  # Produced for callers (target_probe_ip's network_mode: host check, and
  # later tasks); shellcheck cannot see that use from this file alone.
  # shellcheck disable=SC2034
  SELF_IMAGE=$(docker inspect "$SELF_ID" --format '{{.Config.Image}}')

  COMPOSE_PROJECT=$(_label "$SELF_ID" com.docker.compose.project)
  [ -n "$COMPOSE_PROJECT" ] || log_die "this container is not managed by docker compose"

  # Candidate = sibling service in the same project whose image repository
  # mentions unbound. Deliberately loose so forks and private mirrors work.
  local candidates=() cid
  while read -r cid; do
    [ "$cid" = "$SELF_ID" ] && continue
    case "$(docker inspect "$cid" --format '{{.Config.Image}}')" in
      *unbound*) candidates+=("$cid") ;;
    esac
  done < <(docker ps --no-trunc --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{.ID}}')

  if [ -n "${TARGET_SERVICE:-}" ]; then
    TARGET_CONTAINER=$(docker ps --no-trunc \
      --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
      --filter "label=com.docker.compose.service=$TARGET_SERVICE" --format '{{.ID}}' | head -1)
    [ -n "$TARGET_CONTAINER" ] || log_die "TARGET_SERVICE='$TARGET_SERVICE' not found in project '$COMPOSE_PROJECT'"
  elif [ "${#candidates[@]}" -eq 1 ]; then
    TARGET_CONTAINER="${candidates[0]}"
  else
    local names=""
    for cid in "${candidates[@]:-}"; do names="$names $(_label "$cid" com.docker.compose.service)"; done
    log_die "discovery found ${#candidates[@]} candidate services (${names:-none}) — set TARGET_SERVICE explicitly"
  fi

  TARGET_SERVICE=$(_label "$TARGET_CONTAINER" com.docker.compose.service)
  COMPOSE_WORKDIR=$(_label "$TARGET_CONTAINER" com.docker.compose.project.working_dir)
  local files; files=$(_label "$TARGET_CONTAINER" com.docker.compose.project.config_files)
  [ -n "$files" ] && [ -n "$COMPOSE_WORKDIR" ] || log_die "target container carries no compose file labels"

  COMPOSE_FILE_ARGS=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Compose records relative paths when invoked with one; resolve against workdir.
    case "$f" in /*) : ;; *) f="$COMPOSE_WORKDIR/$f" ;; esac
    [ -r "$f" ] || log_die "compose file '$f' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path"
    COMPOSE_FILE_ARGS+=(-f "$f")
  done < <(printf '%s' "$files" | tr ',' '\n')

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
}

_read_running_mounts() {
  TARGET_STATE_VOLUME=$(docker inspect "$TARGET_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/unbound"}}{{.Name}}{{end}}{{end}}')
  [ -n "$TARGET_STATE_VOLUME" ] || log_die "service '$TARGET_SERVICE' has no named volume on /var/lib/unbound — required to persist the DNSSEC trust anchor and to clone state for the canary"
}

# running_digest — repo@sha256:… actually in service.
running_digest() {
  local img rd
  img=$(docker inspect "$TARGET_CONTAINER" --format '{{.Image}}')
  rd=$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')
  [ -n "$rd" ] || log_die "the running image has no repository digest (locally built?) — refusing to guess whether an update is due"
  printf '%s\n' "$rd"
}

# declared_digest — repo@sha256:… of the declared image. Caller must have
# pulled first. Pulling before verifying is safe: pulling is not running.
declared_digest() {
  local rd
  rd=$(docker image inspect "$DECLARED_IMAGE_REF" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null)
  [ -n "$rd" ] || log_die "declared image '$DECLARED_IMAGE_REF' has no repository digest after pull"
  printf '%s\n' "$rd"
}

# config_fingerprint — one sha256 over every declared bind-mounted file,
# ordered. Covering all of them (not just unbound.conf) is intended: a
# rotated certificate or any other bind-mounted file changing must trigger a
# canary and a redeploy just as surely as an edited unbound.conf does.
config_fingerprint() {
  local src paths=()
  local i
  for (( i = 0; i < ${#DECLARED_BIND_MOUNTS[@]}; i++ )); do
    [ "${DECLARED_BIND_MOUNTS[$i]}" = "-v" ] || continue
    src="${DECLARED_BIND_MOUNTS[$((i+1))]%%:*}"
    paths+=("$src")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    printf '%s\n' "$(printf '' | sha256sum | cut -d' ' -f1)"
    return 0
  fi
  # NUL-delimited throughout: a declared path may contain spaces (a compose
  # project can live anywhere on the host), and `sort`/`xargs`'s default
  # whitespace splitting would silently hash the wrong files instead of
  # failing loudly.
  printf '%s\n' "$(printf '%s\0' "${paths[@]}" | sort -z | xargs -0 cat | sha256sum | cut -d' ' -f1)"
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
