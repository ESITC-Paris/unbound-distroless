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
        "${DECLARED_CONF_MOUNTS[@]}" "$ref" /etc/unbound/unbound.conf 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_error "preflight: the declared configuration is not valid for $ref"
    printf '%s\n' "$out" >&2
    return 1
  fi

  _preflight_remote_control_files "$ref" || return 1

  log_info "preflight: configuration accepted by $ref"
  return 0
}

# _checkconf_opt <option> <image_ref> — resolved value of a single-valued
# unbound.conf option (docker compose's `-o`), empty on failure. May print
# more than one line for a list option such as control-interface.
_checkconf_opt() {
  docker run --rm --entrypoint /usr/local/sbin/unbound-checkconf \
    "${DECLARED_CONF_MOUNTS[@]}" "$2" -o "$1" /etc/unbound/unbound.conf 2>/dev/null || true
}

# _preflight_remote_control_files <image_ref>
# unbound-checkconf only validates the remote-control key/cert files when the
# FIRST control-interface in the merged config is an address rather than a
# unix socket (unbound's options_remote_is_address(), config_file.c). Our own
# healthcheck's control-interface is a unix socket declared ahead of anything
# a user's config adds, so a TCP/TLS remote-control appended afterwards is
# silently accepted by checkconf even when the certificate files it names do
# not exist — checkconf never looks at them in that ordering. If the declared
# config implies a TLS control channel (any control-interface is an address),
# verify the four files ourselves, reusing unbound-checkconf's own "could not
# open" error to name the missing one precisely.
_preflight_remote_control_files() {
  local ref="$1"
  [ "$(_checkconf_opt control-enable "$ref")" = yes ] || return 0

  local line wants_tls=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in /*) ;; *) wants_tls=1 ;; esac
  done < <(_checkconf_opt control-interface "$ref")
  [ "$wants_tls" -eq 1 ] || return 0

  local key path out rc
  for key in server-key-file server-cert-file control-key-file control-cert-file; do
    path=$(_checkconf_opt "$key" "$ref")
    [ -n "$path" ] || continue
    rc=0
    out=$(docker run --rm --entrypoint /usr/local/sbin/unbound-checkconf \
          "${DECLARED_CONF_MOUNTS[@]}" "$ref" "$path" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'No such file or directory' <<<"$out"; then
      log_error "preflight: remote-control $key is not usable for $ref"
      printf '%s\n' "$out" >&2
      return 1
    fi
  done
  return 0
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

  docker run -d --name "$CANARY_NAME" --network "$CANARY_NET" \
    --cap-drop=ALL --cap-add=NET_BIND_SERVICE --security-opt no-new-privileges \
    -v "$CANARY_VOL":/var/lib/unbound "${DECLARED_CONF_MOUNTS[@]}" \
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
