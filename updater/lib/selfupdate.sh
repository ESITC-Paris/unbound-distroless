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

  # What runs is this container's image ID (lib/discover.sh, "Image
  # identity"): it needs no repository digest, so a sidecar whose image record
  # lost its name — its tag pulled over by anyone — still updates itself
  # rather than switching self-update off without a word.
  local self_service running cfg self_ref declared new_id s
  self_service=$(_label "$SELF_ID" com.docker.compose.service)
  running=$(describe_image "$SELF_IMAGE_ID" "$(_image_repo "$SELF_IMAGE")")

  # What is declared for the SIDECAR is read from the files the sidecar's own
  # container was created from, not from the resolver's: the two are the same
  # in normal operation (one `docker compose up` creates both), and differ
  # exactly when an operator has recreated the sidecar with an extra override
  # — a digest pin while a broken sidecar release is investigated. Reading the
  # resolver's list made such a pin invisible here, and self-update then
  # recreated the sidecar on the very tag the pin was there to avoid. A
  # `local` copy shadows COMPOSE_FILE_ARGS for every function called below,
  # the helper's file list included. An unreadable file is not fatal here: the
  # resolver's work is already done and recorded, so self-update is skipped,
  # loudly, rather than turning that cycle into an error.
  local COMPOSE_FILE_ARGS=("${COMPOSE_FILE_ARGS[@]}") self_files self_paths f
  self_files=$(_label "$SELF_ID" com.docker.compose.project.config_files)
  if [ -n "$self_files" ]; then
    self_paths=$(_compose_file_paths "$self_files") \
      || { log_warn "self-update: a compose file my own container was created from is not readable — skipped"; return 0; }
    COMPOSE_FILE_ARGS=()
    while IFS= read -r f; do [ -n "$f" ] && COMPOSE_FILE_ARGS+=(-f "$f"); done <<<"$self_paths"
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

  # Resolved in the registry and pulled BY DIGEST: the sidecar's tag is not
  # moved before the new image is verified — that tag is what `docker compose
  # run … check` and any `compose up` by hand would start with the Docker
  # socket. Only the helper moves it, at swap time.
  if ! declared=$(resolve_registry_digest "$self_ref") || ! pull_by_digest "$declared"; then
    log_warn "self-update: cannot fetch '$self_ref' from its registry — skipped"
    return 0
  fi
  new_id=$(image_id_of "$declared")
  [ -n "$new_id" ] || { log_warn "self-update: $declared has no local record after the pull — skipped"; return 0; }
  [ "$new_id" != "$SELF_IMAGE_ID" ] || return 0

  if self_quarantine_active "$declared"; then
    log_warn "self-update: $declared is quarantined after a failed self-update — not retrying yet"
    return 0
  fi

  # Verified BEFORE its version label is read: an unsigned image labelled
  # with the next major version used to be a quiet "major bump not applied"
  # and a green cycle, every hour, and the missing signature on the image
  # that would run with the Docker socket was never reported.
  if ! verify_image "$declared" sidecar; then
    _self_report_unverified "$declared" "$running"
    return 1
  fi
  local old_v new_v
  old_v=$(container_version "$SELF_ID"); new_v=$(image_version_label "$declared")
  if major_bump "$old_v" "$new_v" && [ "${ALLOW_MAJOR:-0}" != 1 ]; then
    log_warn "self-update: $MAJOR_REASON — refused (set ALLOW_MAJOR=1 to accept)"
    notify skipped "sidecar major version bump not applied" "The declared sidecar image moves unbound-autoupdate from $old_v to $new_v. Major bumps are a deliberate human decision; set ALLOW_MAJOR=1 to allow them."
    return 0
  fi
  [ -z "$MAJOR_NOTE" ] || log_warn "self-update: $MAJOR_NOTE"
  # Downgrade guard, after verification too (the labels are the pipeline's
  # own): see the resolver's in unbound-autoupdate.
  if version_downgrade "$old_v" "$new_v" && [ "${ALLOW_DOWNGRADE:-0}" != 1 ]; then
    log_warn "self-update: downgrade $old_v -> $new_v refused (set ALLOW_DOWNGRADE=1 to accept)"
    notify skipped "sidecar downgrade not applied" "The declared sidecar image $declared is unbound-autoupdate $new_v, OLDER than the running $old_v. A downgrade is a deliberate human decision; set ALLOW_DOWNGRADE=1 to allow it."
    return 0
  fi
  [ -z "$DOWNGRADE_NOTE" ] || log_warn "self-update: $DOWNGRADE_NOTE"
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
        "$declared" self-update-apply "$COMPOSE_PROJECT" "$COMPOSE_WORKDIR" "$SELF_IMAGE_ID" "$declared" \
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

# _self_report_unverified <declared> <running> — the log line and the
# notification for a sidecar image that did not pass verification, worded
# alike: "could not be checked" for a transport failure (VERIFY_FAILURE =
# unavailable: registry, rate limit, transparency log), "FAILED" for a
# signature that was checked and refused.
_self_report_unverified() {
  if [ "${VERIFY_FAILURE:-refused}" = unavailable ]; then
    log_error "self-update: the signature of $1 could not be checked (registry or transparency log unreachable) — not replacing myself"
    notify blocked "sidecar signature could not be checked" "Sidecar image $1 could not be verified: the registry or the transparency log did not answer. The sidecar keeps running $2; the next cycle tries again."
  else
    log_error "self-update: cosign verification FAILED for $1 — refusing to replace myself"
    notify blocked "sidecar signature verification FAILED" "Sidecar image $1 is not signed by the expected identity. The sidecar keeps running $2. Investigate immediately: an unsigned sidecar image in the registry is a supply-chain incident."
  fi
}

# _self_services_on_image <image-id> <services…> — 0 when every one of them
# runs exactly that image ID. A new container id says Compose did something;
# it does not say WHAT it deployed. The container's .Image is the identity of
# what it runs on both image stores, whatever tags or digests say.
_self_services_on_image() {
  local want="$1"; shift
  local s cid
  [ -n "$want" ] || return 1
  for s in "$@"; do
    cid=$(compose ps -q "$s" 2>/dev/null | head -1)
    [ -n "$cid" ] || return 1
    [ "$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null)" = "$want" ] || return 1
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

# _self_wait_for_launching_cycle — block until the cycle that started this
# helper has ended, i.e. until the cycle lock is free, then let go of it.
#
# That cycle runs INSIDE the sidecar container this helper is about to
# replace, and it is not over when it launches the helper: it still sends
# its health-check ping, records its outcome (state.env, metrics.prom) and
# exits. Recreating the sidecar under it stops that container, and every
# process in it is killed outright — the cycle's outcome is then lost or
# half-written, and a `docker compose exec … once` driving it ends with 137
# instead of the cycle's own status. The lock is the cycle's own "I am done"
# signal (it is held from the start of the cycle until its process exits),
# so waiting for it costs nothing on a host where the cycle ends at once.
# Not held across the `compose up`: the recreated sidecar starts a cycle of
# its own straight away, which must not find the lock taken. Running out of
# the wait is loud but not fatal, as for the state writes: the update the
# helper exists for still goes ahead.
_self_wait_for_launching_cycle() {
  exec 9>"$LOCK_FILE"
  flock -w "$SELF_LOCK_WAIT" 9 \
    || log_error "self-update helper: the cycle lock is still held after ${SELF_LOCK_WAIT}s — recreating the sidecar anyway"
  exec 9>&-
  return 0
}

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
  # Nothing is touched — not even the sidecar's tag — while the cycle that
  # launched this helper is still finishing inside the container it replaces.
  _self_wait_for_launching_cycle

  # The sidecar's own service moves FIRST and ALONE. Everything else declared
  # on the same image (the metrics endpoint) only follows once the new image
  # has proved it can run as the sidecar, so an image that cannot start costs
  # one container instead of every container on that image — and leaves the
  # metrics endpoint answering while the rollback happens.
  # Every `compose up` below deploys exactly the verified digest, with the
  # operator's own compose files: the local tag is moved onto it here, at swap
  # time and not before (tag_for_deploy), and Compose may not pull (`--pull never` overrides `pull_policy:
  # always`), so a tag moved in the registry since verification cannot be
  # what starts with the Docker socket; and the containers keep the
  # configuration hash the operator's own `docker compose up -d` computes, so
  # that command does not recreate them — possibly mid-cycle — afterwards.
  # The identity gate further down checks what actually runs. A reference
  # that cannot be named locally is never deployed: the failure path below
  # then quarantines it like any other failed self-update.
  local cfg self_ref="" new_id old_id
  if cfg=$(compose config --format json 2>/dev/null); then
    self_ref=$(jq -r --arg s "$self_service" '.services[$s].image // empty' <<<"$cfg")
  fi
  # <new> is the digest this helper runs from, so its record exists. <old> is
  # the previous sidecar's image ID — or, when an OLDER sidecar launched this
  # helper, its repository digest: both are accepted, and a digest whose
  # record has gone is pulled back by digest.
  new_id=$(image_id_of "$new")
  case "$old" in
    sha256:*) old_id="$old" ;;
    *) old_id=$(image_id_of "$old")
       if [ -z "$old_id" ] && pull_by_digest "$old"; then old_id=$(image_id_of "$old"); fi ;;
  esac
  if [ -z "$self_ref" ] || [ -z "$new_id" ] || ! tag_for_deploy "$self_ref" "$new_id"; then
    ok=0; log_error "self-update helper: cannot point the sidecar's declared image at $new"
  fi

  local before_self; before_self=$(_self_service_cids "$self_service")
  if [ "$ok" = 1 ]; then
    log_info "self-update helper: recreating $self_service on $new"
    out=$(compose up -d --no-deps --pull never "$self_service" 2>&1) || ok=0
    if [ "$ok" = 0 ]; then
      log_error "self-update helper: docker compose up failed"
      printf '%s\n' "$out" >&2
    fi
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
  if [ "$ok" = 1 ] && ! _self_services_on_image "$new_id" "$self_service"; then
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
    out=$(compose up -d --no-deps --pull never "${rest[@]}" 2>&1) || ok=0
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
    elif ! _self_services_on_image "$new_id" "${rest[@]}"; then
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

  # Back the same way: the tag moved back onto the previous image ID (its
  # record kept alive by keep_running, so no registry is needed) and every
  # moved service recreated (--force-recreate: one Compose did move must not
  # be kept). Only a digest-declared sidecar — which no tag can express —
  # falls back to an override file pinning the sidecar's keep name.
  log_error "self-update helper: rolling ${moved[*]} back to $old"
  local rb_ok=1 self_repo
  self_repo=$(familiar_repo "$(_image_repo "${self_ref:-$new}")")
  if [ -z "$old_id" ] || [ -z "$(image_id_of "$old_id")" ]; then
    rb_ok=0; out="the previous sidecar image $old has no local record"
  else
    case "$self_ref" in
      ""|*@*)
        COMPOSE_EXTRA_FILE="$SELF_ROLLBACK_FILE"
        if keep_running "$(keep_name "$self_repo" "$COMPOSE_PROJECT" "$self_service")" "$old_id" \
           && write_pin_file "$COMPOSE_EXTRA_FILE" "$(keep_name "$self_repo" "$COMPOSE_PROJECT" "$self_service")" "${moved[@]}"; then
          out=$(compose up -d --no-deps --pull never --force-recreate "${moved[@]}" 2>&1) || rb_ok=0
        else
          rb_ok=0; out="no local name for the previous sidecar image"
        fi
        unset COMPOSE_EXTRA_FILE ;;
      *)
        if tag_for_deploy "$self_ref" "$old_id"; then
          out=$(compose up -d --no-deps --pull never --force-recreate "${moved[@]}" 2>&1) || rb_ok=0
        else
          rb_ok=0; out="cannot move $self_ref back to $old_id"
        fi ;;
    esac
  fi
  if [ "$rb_ok" = 1 ] && ! _self_services_on_image "$old_id" "${moved[@]}"; then
    rb_ok=0; out="the rolled-back services do not run $old"
  fi
  [ "$rb_ok" = 1 ] || { log_error "self-update helper: rollback compose up failed"; printf '%s\n' "$out" >&2; }
  _self_update_record_failure "$new"
  if [ "$rb_ok" = 1 ]; then
    notify critical "sidecar self-update FAILED — rolled back" "The new sidecar image $new did not come up. Services ${moved[*]} were put back on $old. $new is quarantined for RETRY_AFTER=${RETRY_AFTER:-24h}. The compose file still declares the failing tag: a 'docker compose pull' followed by 'up -d' by hand would redeploy it."
  else
    notify critical "CRITICAL: sidecar self-update FAILED and rollback failed" "Neither $new nor $old could be brought up for ${moved[*]}. Automatic updates are DOWN on this host. MANUAL INTERVENTION REQUIRED."
  fi
  hc_fail "self-update failed"
  exit 1
}
