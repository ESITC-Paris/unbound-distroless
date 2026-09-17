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
  local files="$1" f
  # A hard failure, not a "${ROLLBACK_FILE:-}" fallback. If this is ever empty
  # — state.sh sourced after this file, or STATE_DIR differing between cycles
  # — the comparison below silently matches nothing and the rollback override
  # walks straight back into the project definition, which is Bug B returning
  # with no error at all. That class of regression has to be loud.
  [ -n "${ROLLBACK_FILE:-}" ] || log_die "internal error: ROLLBACK_FILE is unset — state.sh must be sourced before discover.sh"

  COMPOSE_FILE_ARGS=()
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
    if [ "$f" = "$ROLLBACK_FILE" ] || [ "$f" = "${SELF_ROLLBACK_FILE:-}" ]; then continue; fi
    [ -r "$f" ] || log_die "compose file '$f' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path"
    COMPOSE_FILE_ARGS+=(-f "$f")
  done < <(printf '%s\n' "$files" | tr ',' '\n')
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
  local candidates=() cid img self_repo
  self_repo=$(_image_repo "$SELF_IMAGE")
  while read -r cid; do
    [ "$cid" = "$SELF_ID" ] && continue
    img=$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null) || continue
    [ "$(_image_repo "$img")" = "$self_repo" ] && continue
    case "$img" in
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

# running_digest — repo@sha256:… actually in service.
running_digest() {
  local img digests rd
  img=$(docker inspect "$TARGET_CONTAINER" --format '{{.Image}}')
  digests=$(_repo_digests "$img") || digests=""
  # The declared repository's own entry when the running image has one. It
  # legitimately has none the moment the declaration moves to a different
  # repository, and the first entry is then simply what this image is known
  # as — silently, because that is an ordinary update, not an anomaly.
  rd=$(_digest_for_repo "$(_image_repo "${DECLARED_IMAGE_REF:-}")" "$digests") \
    || rd=$(printf '%s\n' "$digests" | head -1)
  [ -n "$rd" ] || log_die "the running image has no repository digest (locally built?) — refusing to guess whether an update is due"
  printf '%s\n' "$rd"
}

# declared_digest — repo@sha256:… of the declared image. Caller must have
# pulled first. Pulling before verifying is safe: pulling is not running.
declared_digest() {
  local repo digests rd
  repo=$(_image_repo "$DECLARED_IMAGE_REF")
  digests=$(_repo_digests "$DECLARED_IMAGE_REF") || digests=""
  if ! rd=$(_digest_for_repo "$repo" "$digests"); then
    rd=$(printf '%s\n' "$digests" | head -1)
    # Here the fallback IS worth a word: the image was just pulled from this
    # very repository, so an entry for it should exist. Carrying on with
    # another repository's digest is deliberate (it is still the right bits),
    # but the operator should see which repository the verdict came from.
    if [ -n "$rd" ]; then
      log_warn "declared image '$DECLARED_IMAGE_REF' carries no repository digest for '$repo' — using '$rd' instead"
    fi
  fi
  [ -n "$rd" ] || log_die "declared image '$DECLARED_IMAGE_REF' has no repository digest after pull"
  printf '%s\n' "$rd"
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
  local src paths=()
  local i
  for (( i = 0; i < ${#DECLARED_BIND_MOUNTS[@]}; i++ )); do
    [ "${DECLARED_BIND_MOUNTS[$i]}" = "-v" ] || continue
    src="${DECLARED_BIND_MOUNTS[$((i+1))]%%:*}"
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
