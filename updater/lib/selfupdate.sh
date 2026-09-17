#!/usr/bin/env bash
# Self-update of the sidecar. Detection and the guards run inside the
# sidecar at the end of a successful cycle; the recreation itself runs in
# an EPHEMERAL HELPER container started from the new, verified image. A
# `compose up -d` issued from the container being replaced dies the moment
# Compose stops that container — before the new one is started — so the
# only correct place to run it is outside.

SELF_UPDATE="${SELF_UPDATE:-1}"
# How long the helper waits for the cycle lock before writing state anyway. A
# cycle legitimately holds it for minutes — the canary waits up to 90 s then
# validates, the post-swap and rollback gates 45 s each plus their own probes,
# and every one of those sits behind a registry pull.
SELF_LOCK_WAIT="${SELF_LOCK_WAIT:-900}"
# Read by the orchestrator to tell "nothing to do" from "a helper is now
# recreating me"; shellcheck cannot see that use from this file alone.
# shellcheck disable=SC2034
SELF_UPDATE_LAUNCHED=0

# _self_state_mount — a -v argument giving a helper this sidecar's state
# volume (or bind mount) at the same STATE_DIR path.
_self_state_mount() {
  local name src
  name=$(docker inspect "$SELF_ID" --format "{{range .Mounts}}{{if eq .Destination \"$STATE_DIR\"}}{{.Name}}{{end}}{{end}}")
  if [ -n "$name" ]; then printf '%s:%s\n' "$name" "$STATE_DIR"; return 0; fi
  src=$(docker inspect "$SELF_ID" --format "{{range .Mounts}}{{if eq .Destination \"$STATE_DIR\"}}{{.Source}}{{end}}{{end}}")
  [ -n "$src" ] || return 1
  printf '%s:%s\n' "$src" "$STATE_DIR"
}

# _self_running_digest — repo@sha256:… of the image this sidecar actually
# runs, or empty when that image was built locally and never pushed.
#
# The obvious source is the image record's RepoDigests, and it is used first.
# It disappears in one case that matters: a daemon using the containerd image
# store drops an image the moment its last REFERENCE goes, and the sidecar's
# own tag moves to the new image as soon as anything pulls it — while this
# container keeps running content that no longer has an image record at all.
# `docker image inspect` then fails outright, which is NOT the same thing as
# "this image has no repository digest" and must not be reported as one:
# without the digest it is running, the sidecar cannot compare, and the helper
# would have no rollback target. On that store an image ID IS the digest of
# what was pulled — for a registry image the container's .Image, the image's
# .Id and its RepoDigests entry are all the same sha256 — so the repository
# part of my own reference plus that ID reconstructs the digest exactly.
# ImageManifestDescriptor is populated only by the containerd image store, so
# its presence is what makes relying on that identity safe.
_self_running_digest() {
  local rd imd
  if rd=$(docker image inspect "$SELF_IMAGE_ID" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null); then
    printf '%s\n' "$rd"
    return 0
  fi
  imd=$(docker inspect "$SELF_ID" --format '{{if .ImageManifestDescriptor}}{{.ImageManifestDescriptor.digest}}{{end}}' 2>/dev/null) || imd=""
  [ -n "$imd" ] || return 0
  printf '%s@%s\n' "$(_image_repo "$SELF_IMAGE")" "$SELF_IMAGE_ID"
}

# _compose_files_csv — COMPOSE_FILE_ARGS (-f a -f b) back to "a,b".
_compose_files_csv() {
  local i csv=""
  for (( i = 1; i < ${#COMPOSE_FILE_ARGS[@]}; i += 2 )); do csv="$csv,${COMPOSE_FILE_ARGS[$i]}"; done
  printf '%s\n' "${csv#,}"
}

# self_update — run at the end of a cycle that ended "up to date" or
# "updated"; never after a failure and never in check mode.
#   0: nothing to do, deliberately skipped, or helper launched (SELF_UPDATE_LAUNCHED=1)
#   1: the new image failed verification or the helper could not start —
#      a supply-chain incident the caller must report as a failed cycle.
# SELF_UPDATE_LAUNCHED is written for the caller, not read back here.
# shellcheck disable=SC2034
self_update() {
  SELF_UPDATE_LAUNCHED=0
  [ "$SELF_UPDATE" = 1 ] || return 0

  # A helper launched by an earlier cycle may still be at work: it recreates
  # the sidecar, then waits 30 s on it before moving the other services. A
  # second helper would run `compose up` on the very containers the first one
  # is still judging, and each would draw its verdict from the other's work.
  # One at a time, always — the next cycle picks the update up.
  local helpers
  helpers=$(docker ps -q --filter label=unbound-autoupdate.helper=1 2>/dev/null) || helpers=""
  if [ -n "$helpers" ]; then
    log_info "self-update: a helper is still running — skipped"
    return 0
  fi

  local self_service running cfg self_ref declared s
  self_service=$(_label "$SELF_ID" com.docker.compose.service)
  running=$(_self_running_digest)
  if [ -z "$running" ]; then
    log_info "self-update: my image carries no repository digest (locally built) — skipped"
    return 0
  fi

  cfg=$(compose config --format json) || { log_warn "self-update: docker compose config failed — skipped"; return 0; }
  self_ref=$(jq -r --arg s "$self_service" '.services[$s].image // empty' <<<"$cfg")
  [ -n "$self_ref" ] || { log_warn "self-update: service '$self_service' declares no image — skipped"; return 0; }

  # Every service of the project declared on the same image is handed to the
  # helper (the loop and the metrics service). Own service FIRST: the helper
  # moves it alone, waits on it, and only then moves the others.
  local ordered=("$self_service")
  while read -r s; do
    [ -n "$s" ] && [ "$s" != "$self_service" ] && ordered+=("$s")
  done < <(jq -r --arg r "$self_ref" '.services | to_entries[] | select(.value.image == $r) | .key' <<<"$cfg")

  local pull_out
  if ! pull_out=$(compose pull --quiet "$self_service" 2>&1); then
    log_warn "self-update: docker compose pull failed — skipped"
    printf '%s\n' "$pull_out" >&2
    return 0
  fi
  declared=$(docker image inspect "$self_ref" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null) || declared=""
  [ -n "$declared" ] || { log_warn "self-update: '$self_ref' has no repository digest after pull — skipped"; return 0; }
  [ "$declared" != "$running" ] || return 0

  if self_quarantine_active "$declared"; then
    log_warn "self-update: $declared is quarantined after a failed self-update — not retrying yet"
    return 0
  fi

  local old_v new_v
  old_v=$(image_version_label "$running"); new_v=$(image_version_label "$declared")
  if [ -n "$old_v" ] && [ -n "$new_v" ] && [ "${old_v%%.*}" != "${new_v%%.*}" ] && [ "${ALLOW_MAJOR:-0}" != 1 ]; then
    log_warn "self-update: major version bump $old_v -> $new_v refused (set ALLOW_MAJOR=1 to accept)"
    notify skipped "sidecar major version bump not applied" "The declared sidecar image moves unbound-autoupdate from $old_v to $new_v. Major bumps are a deliberate human decision; set ALLOW_MAJOR=1 to allow them."
    return 0
  fi

  if ! verify_image "$declared"; then
    log_error "self-update: cosign verification FAILED for $declared — refusing to replace myself"
    notify blocked "sidecar signature verification FAILED" "Sidecar image $declared is not signed by the expected identity. The sidecar keeps running $running. Investigate immediately: an unsigned sidecar image in the registry is a supply-chain incident."
    return 1
  fi
  log_info "self-update: cosign signature verified for $declared"

  local state_mount
  state_mount=$(_self_state_mount) || { log_warn "self-update: cannot find my state volume — skipped"; return 0; }
  local mounts=(-v /var/run/docker.sock:/var/run/docker.sock -v "$COMPOSE_WORKDIR:$COMPOSE_WORKDIR:ro" -v "$state_mount")
  local i f
  for (( i = 1; i < ${#COMPOSE_FILE_ARGS[@]}; i += 2 )); do
    f="${COMPOSE_FILE_ARGS[$i]}"
    case "$f" in "$COMPOSE_WORKDIR"/*) : ;; *) mounts+=(-v "$f:$f:ro") ;; esac
  done

  # SELF_LOCK_WAIT is forwarded like the notification settings: it is the
  # HELPER, not this cycle, that waits for the cycle lock, so an operator who
  # tuned it here would otherwise have tuned nothing at all. `-e NAME` passes
  # it only when it is actually set in the environment, leaving the helper on
  # its own default otherwise.
  log_info "self-update: $running -> $declared; launching the apply helper for: ${ordered[*]}"
  if ! docker run -d --rm --label unbound-autoupdate.helper=1 \
        "${mounts[@]}" \
        -e WEBHOOK_URL -e HC_URL -e NOTIFY_HOST -e RETRY_AFTER -e "STATE_DIR=$STATE_DIR" \
        -e SELF_LOCK_WAIT \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$declared" self-update-apply "$COMPOSE_PROJECT" "$COMPOSE_WORKDIR" "$running" "$declared" \
        "$(_compose_files_csv)" "${ordered[@]}" >/dev/null; then
    log_error "self-update: could not launch the apply helper"
    notify blocked "sidecar self-update could not start" "The helper container for $declared could not be started. The sidecar keeps running $running."
    return 1
  fi
  SELF_UPDATE_LAUNCHED=1
  return 0
}

# _self_services_healthy <services…> — 0 when every one of them has a
# container that is running and has not restarted. `compose ps -q` lists only
# running containers, so a sidecar that died at start shows up here as "no
# container", which is exactly the verdict wanted.
_self_services_healthy() {
  local s cid
  for s in "$@"; do
    cid=$(compose ps -q "$s" 2>/dev/null | head -1)
    [ -n "$cid" ] || return 1
    [ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null)" = true ] || return 1
    [ "$(docker inspect "$cid" --format '{{.RestartCount}}' 2>/dev/null)" = 0 ] || return 1
  done
  return 0
}

# _self_service_cids <services…> — "service<TAB>container-id" per line, the
# snapshot a `compose up` must be seen to change. Taken BEFORE the command,
# because "which container is this service on" is the only question whose
# answer distinguishes a real recreation from Compose deciding it had nothing
# to do.
_self_service_cids() {
  local s
  for s in "$@"; do
    printf '%s\t%s\n' "$s" "$(compose ps -q "$s" 2>/dev/null | head -1)"
  done
}

# _self_services_recreated <before> <services…> — <before> is the output of
# _self_service_cids for those same services; 0 when every one of them now
# runs a DIFFERENT container.
#
# `compose up` exiting 0 is not proof it recreated anything, and the OLD
# container satisfies _self_services_healthy perfectly: it is running and has
# never restarted. Without this check a Compose that declines to recreate
# (a stale config hash, an unexpected --no-deps interaction, anything) makes
# the helper clear the quarantine, stamp SELF_UPDATE_TS and notify "updated"
# while NOTHING changed — a false "updated" on every single cycle, forever.
# The orchestrator already refuses to trust a swap it cannot see in the
# running container; the helper holds to the same standard.
_self_services_recreated() {
  local before="$1"; shift
  local s old now
  for s in "$@"; do
    old=$(printf '%s\n' "$before" | awk -F'\t' -v s="$s" '$1 == s { print $2 }')
    now=$(compose ps -q "$s" 2>/dev/null | head -1)
    [ -n "$now" ] || return 1
    [ "$now" != "$old" ] || return 1
  done
  return 0
}

# _self_services_on_image <new_digest> <services…> — 0 when every one of them
# runs exactly <new_digest>. A new container id says Compose did something; it
# does not say WHAT it deployed. With `pull_policy: always` in the project, the
# helper's own `compose up` pulls again and can land on a digest other than the
# one verify_image approved — an unverified sidecar image, which is the single
# thing this whole path exists to prevent.
#
# The container was created from the `image:` reference the compose file
# declares (a tag), so .Config.Image is that tag and never a digest: the
# identity has to come from the RepoDigests of the image the container
# actually runs. The ImageManifestDescriptor fallback covers the containerd
# image store hole _self_running_digest documents — the image record can be
# gone while the container keeps running its content, and there an image ID IS
# the digest of what was pulled.
_self_services_on_image() {
  local new="$1"; shift
  local s cid img digests imd
  for s in "$@"; do
    cid=$(compose ps -q "$s" 2>/dev/null | head -1)
    [ -n "$cid" ] || return 1
    img=$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null) || return 1
    [ -n "$img" ] || return 1
    if digests=$(docker image inspect "$img" --format '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' 2>/dev/null) \
       && printf '%s\n' "$digests" | grep -qxF "$new"; then
      continue
    fi
    imd=$(docker inspect "$cid" --format '{{if .ImageManifestDescriptor}}{{.ImageManifestDescriptor.digest}}{{end}}' 2>/dev/null) || imd=""
    [ -n "$imd" ] && [ "$(_image_repo "$new")@$imd" = "$new" ] || return 1
  done
  return 0
}

# _self_take_cycle_lock / _self_release_cycle_lock — the helper writes the SAME
# state file a cycle writes, from a different container, and by the time it
# gets here the sidecar it has just recreated may already be running its first
# cycle under that cycle's own flock. state_set is read-modify-write (grep -v
# into a temporary file, then mv), so two writers interleaving silently drop
# each other's keys — and the key at stake on the failure path is the self
# quarantine: lose it and the sidecar image that cannot start is relaunched on
# every single cycle, which is precisely what the quarantine exists to stop.
# The compose work deliberately stays OUTSIDE the lock; only the state
# mutations need it, and holding it across a 30 s soak would block cycles for
# no reason.
#
# Running out of that wait is NOT a reason to give up on the write. Dying here
# would skip the quarantine, the metrics and the notification on a path where
# the rollback has already happened — and a missing quarantine guarantees the
# broken image is relaunched on every cycle from then on, silently. An
# unlocked write only risks a state.env the next cycle rewrites anyway. So the
# timeout is loud and the writes go ahead: this always returns 0.
_self_take_cycle_lock() {
  exec 9>"$LOCK_FILE"
  flock -w "$SELF_LOCK_WAIT" 9 \
    || log_error "self-update helper: could not take the cycle lock within ${SELF_LOCK_WAIT}s — writing state without it"
  return 0
}
_self_release_cycle_lock() { exec 9>&-; }

# _self_update_record_success / _self_update_record_failure <new_digest> — the
# helper's state mutations, under the cycle lock, in functions of their own so
# the locking itself can be tested directly.
_self_update_record_success() {
  _self_take_cycle_lock
  self_quarantine_clear
  state_set SELF_UPDATE_TS "$(date -u +%s)"
  write_cycle_metrics
  _self_release_cycle_lock
}

_self_update_record_failure() {
  _self_take_cycle_lock
  self_quarantine_set "$1"
  write_cycle_metrics
  _self_release_cycle_lock
}

# self_update_apply <project> <workdir> <old_digest> <new_digest> <files_csv> <self_service> [services…]
# Runs in the ephemeral helper, on the NEW image. Never returns.
self_update_apply() {
  COMPOSE_PROJECT="$1"; COMPOSE_WORKDIR="$2"
  local old="$3" new="$4" files="$5"; shift 5
  local services=("$@") self_service="$1" s out ok=1
  local moved=("$self_service")
  state_init
  _compose_file_args "$files"

  # The sidecar's own service moves FIRST and ALONE. Everything else declared
  # on the same image (the metrics endpoint) only follows once the new image
  # has proved it can run as the sidecar, so an image that cannot start costs
  # one container instead of every container on that image — and leaves the
  # metrics endpoint answering while the rollback happens.
  log_info "self-update helper: recreating $self_service on $new"
  local before_self; before_self=$(_self_service_cids "$self_service")
  out=$(compose up -d --no-deps "$self_service" 2>&1) || ok=0
  if [ "$ok" = 0 ]; then
    log_error "self-update helper: docker compose up failed"
    printf '%s\n' "$out" >&2
  fi

  # The new container must be running, and still running with no restart,
  # 30 s later: a sidecar that dies at start would otherwise pass a
  # single instant check.
  if [ "$ok" = 1 ]; then
    local deadline healthy=0
    deadline=$(( $(date -u +%s) + 30 ))
    while :; do
      if _self_services_healthy "$self_service"; then healthy=1; else healthy=0; fi
      [ "$(date -u +%s)" -ge "$deadline" ] && break
      sleep 3
    done
    [ "$healthy" = 1 ] || { ok=0; log_error "self-update helper: the new sidecar is not running 30 s after recreation"; }
  fi

  # Healthy is not the same as NEW. The gate below is the one the orchestrator
  # already applies to production: a genuine Compose recreation always yields a
  # different container id, and the container it yields must run the digest
  # that was verified. Without it, a Compose that declines to recreate leaves
  # the OLD container in place — running, never restarted, passing the soak
  # above perfectly — and the helper clears the quarantine, stamps
  # SELF_UPDATE_TS and notifies "updated" while nothing changed at all.
  if [ "$ok" = 1 ] && ! _self_services_recreated "$before_self" "$self_service"; then
    ok=0
    log_error "self-update helper: compose did not recreate $self_service — it is still on the container it had before"
  fi
  if [ "$ok" = 1 ] && ! _self_services_on_image "$new" "$self_service"; then
    ok=0
    log_error "self-update helper: $self_service was recreated but does not run $new"
  fi

  # Only now the rest of the project's services on that image. They are
  # recorded as moved even if the command failed, because some of them may
  # already have been recreated and must be pinned back with the others.
  if [ "$ok" = 1 ] && [ "${#services[@]}" -gt 1 ]; then
    local rest=("${services[@]:1}")
    log_info "self-update helper: the new sidecar is healthy — moving ${rest[*]} to $new"
    local before_rest; before_rest=$(_self_service_cids "${rest[@]}")
    out=$(compose up -d --no-deps "${rest[@]}" 2>&1) || ok=0
    moved=("${services[@]}")
    if [ "$ok" = 0 ]; then
      log_error "self-update helper: docker compose up failed for ${rest[*]}"
      printf '%s\n' "$out" >&2
    elif ! _self_services_healthy "${rest[@]}"; then
      ok=0
      log_error "self-update helper: ${rest[*]} did not come up on $new"
    elif ! _self_services_recreated "$before_rest" "${rest[@]}"; then
      ok=0
      log_error "self-update helper: compose did not recreate ${rest[*]} — they are still on the containers they had before"
    elif ! _self_services_on_image "$new" "${rest[@]}"; then
      ok=0
      log_error "self-update helper: ${rest[*]} were recreated but do not run $new"
    fi
  fi

  if [ "$ok" = 1 ]; then
    _self_update_record_success
    log_info "self-update helper: sidecar now runs $new (services: ${moved[*]})"
    notify updated "sidecar updated" "unbound-autoupdate moved from $old to $new (unbound-autoupdate $(image_version_label "$new")) and its services (${moved[*]}) are running."
    exit 0
  fi

  log_error "self-update helper: rolling ${moved[*]} back to $old"
  COMPOSE_EXTRA_FILE="$SELF_ROLLBACK_FILE"
  {
    printf 'services:\n'
    for s in "${moved[@]}"; do printf '  %s:\n    image: %s\n' "$s" "$old"; done
  } > "$COMPOSE_EXTRA_FILE"
  local rb_ok=1
  out=$(compose up -d --no-deps "${moved[@]}" 2>&1) || rb_ok=0
  unset COMPOSE_EXTRA_FILE
  [ "$rb_ok" = 1 ] || { log_error "self-update helper: rollback compose up failed"; printf '%s\n' "$out" >&2; }
  _self_update_record_failure "$new"
  if [ "$rb_ok" = 1 ]; then
    notify critical "sidecar self-update FAILED — rolled back" "The new sidecar image $new did not come up. Services ${moved[*]} were pinned back to $old. $new is quarantined for RETRY_AFTER=${RETRY_AFTER:-24h}. The compose file still declares the failing tag."
  else
    notify critical "CRITICAL: sidecar self-update FAILED and rollback failed" "Neither $new nor $old could be brought up for ${moved[*]}. Automatic updates are DOWN on this host. MANUAL INTERVENTION REQUIRED."
  fi
  hc_fail "self-update failed"
  exit 1
}
