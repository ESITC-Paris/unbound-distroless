#!/usr/bin/env bash
# Preflight configuration check and canary lifecycle.
#
# The canary runs the NEW image with the DECLARED configuration and a CLONE of
# production state, on an isolated bridge network. Production keeps serving
# throughout and is never touched.

# Names are derived at call time, not at source time: COMPOSE_PROJECT is set
# by discover_target, which necessarily runs after this file is sourced.
_canary_names() {
  [ -n "${COMPOSE_PROJECT:-}" ] || log_die "canary: COMPOSE_PROJECT is unset — discover_target must run first"
  CANARY_NAME="unbound-canary-$COMPOSE_PROJECT"
  CANARY_VOL="unbound-canary-vol-$COMPOSE_PROJECT"
  CANARY_NET="unbound-canary-net-$COMPOSE_PROJECT"
}

# preflight_checkconf <image_ref>
# Runs the new image's own unbound-checkconf against the declared config.
# This is what turns "the canary never became healthy" into an actionable
# error message naming the offending directive or file.
preflight_checkconf() {
  local ref="$1" out rc=0
  out=$(docker run --rm --entrypoint /usr/local/sbin/unbound-checkconf \
        "${DECLARED_BIND_MOUNTS[@]}" "$ref" /etc/unbound/unbound.conf 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_error "preflight: the declared configuration is not valid for $ref"
    printf '%s\n' "$out" >&2
    return 1
  fi

  _warn_plaintext_control_channel "$ref"

  log_info "preflight: configuration accepted by $ref"
  return 0
}

# _warn_plaintext_control_channel <image_ref>
# unbound only enforces remote-control TLS (and the existence of its key/cert
# files) when the FIRST control-interface in the merged config is an address
# rather than a unix socket (unbound's options_remote_is_address(),
# config_file.c). When a unix socket is declared first — ours always is, for
# the container healthcheck — a later address-based control-interface is not
# an error: unbound runs it as plain, unauthenticated TCP and simply ignores
# its key/cert settings. That is a legitimate, working configuration, so this
# never fails the preflight — only warns, since a "TLS" remote-control the
# user configured quietly becoming unauthenticated is easy to miss.
_warn_plaintext_control_channel() {
  local ref="$1" enabled line has_socket=0 has_addr=0
  enabled=$(docker run --rm --entrypoint /usr/local/sbin/unbound-checkconf \
    "${DECLARED_BIND_MOUNTS[@]}" "$ref" -o control-enable /etc/unbound/unbound.conf 2>/dev/null) || return 0
  [ "$enabled" = yes ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in /*) has_socket=1 ;; *) has_addr=1 ;; esac
  done < <(docker run --rm --entrypoint /usr/local/sbin/unbound-checkconf \
    "${DECLARED_BIND_MOUNTS[@]}" "$ref" -o control-interface /etc/unbound/unbound.conf 2>/dev/null)

  if [ "$has_socket" -eq 1 ] && [ "$has_addr" -eq 1 ]; then
    log_warn "preflight: control-interface declares both a unix socket and an address for $ref — unbound will use the unix socket and serve the address as PLAINTEXT, silently ignoring its TLS key/cert settings"
  fi
}

canary_down() {
  _canary_names
  docker network disconnect -f "$CANARY_NET" "$SELF_ID" >/dev/null 2>&1 || true
  docker rm -f "$CANARY_NAME"      >/dev/null 2>&1 || true
  docker volume rm "$CANARY_VOL"   >/dev/null 2>&1 || true
  docker network rm "$CANARY_NET"  >/dev/null 2>&1 || true
}

# canary_up <image_ref> — sets CANARY_IP.
canary_up() {
  local ref="$1"
  _canary_names
  canary_down   # clear leftovers from an interrupted run

  docker network create "$CANARY_NET" >/dev/null || { log_error "canary: cannot create network"; return 1; }
  docker volume create "$CANARY_VOL"  >/dev/null || { log_error "canary: cannot create volume"; return 1; }

  # Clone production state with our OWN image rather than pulling busybox:
  # every image in this chain is signed by the same pipeline.
  docker run --rm --entrypoint /bin/sh \
    -v "$TARGET_STATE_VOLUME":/src:ro -v "$CANARY_VOL":/dst \
    "$SELF_IMAGE" -c 'cp -a /src/. /dst/' \
    || { log_error "canary: cloning production state failed"; return 1; }

  # Same runtime settings as the declared service (read_only, tmpfs,
  # environment, ulimits, sysctls — see _read_declared_runtime), so the
  # canary fails where production would fail and passes where it would pass.
  docker run -d --name "$CANARY_NAME" --network "$CANARY_NET" \
    --cap-drop=ALL --cap-add=NET_BIND_SERVICE --security-opt no-new-privileges \
    -v "$CANARY_VOL":/var/lib/unbound "${DECLARED_BIND_MOUNTS[@]}" \
    "${DECLARED_RUNTIME_ARGS[@]}" \
    "$ref" >/dev/null \
    || { log_error "canary: container failed to start"; return 1; }

  # Join the canary's network so we can query it directly. No published port,
  # so this works regardless of whether container IPs are routable from the host.
  docker network connect "$CANARY_NET" "$SELF_ID" >/dev/null \
    || { log_error "canary: cannot join the canary network"; return 1; }

  CANARY_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$CANARY_NET\").IPAddress}}" "$CANARY_NAME")
  [ -n "$CANARY_IP" ] || { log_error "canary: no IP address"; return 1; }
  log_info "canary running at $CANARY_IP on $ref"
  return 0
}

canary_logs() { _canary_names; docker logs "$CANARY_NAME" 2>&1 | tail -20 || true; }
