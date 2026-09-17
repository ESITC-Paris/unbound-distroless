#!/usr/bin/env bash
# Decision logic of the update monitor (upstream-check.yml), kept out of the
# workflow so tests/monitor.sh can exercise it without GitHub.
#
# Inputs (environment): LATEST (newest upstream Unbound version), NEW_DEBIAN,
# NEW_DISTROLESS, NEW_ALPINE, NEW_COSIGN (freshly resolved digests).
# Files: versions.env, .build-state.json in the current directory.
# Output (stdout): action=version|revision|none  (resolver)
#                  updater_action=revision|none  (sidecar)
set -euo pipefail

for v in LATEST NEW_DEBIAN NEW_DISTROLESS NEW_ALPINE NEW_COSIGN; do
  # An empty digest would compare unequal to the stored one, trigger a
  # spurious release and then be written into .build-state.json, making every
  # later run bump again. Fail loudly instead.
  [ -n "${!v:-}" ] || { echo "::error::$v is empty" >&2; exit 1; }
done

# shellcheck disable=SC1091
. ./versions.env

read_state() { python3 -c "import json,sys;print(json.load(open('.build-state.json')).get(sys.argv[1],''))" "$1"; }
OLD_DEBIAN=$(read_state debian)
OLD_DISTROLESS=$(read_state distroless)
OLD_ALPINE=$(read_state alpine)
OLD_COSIGN=$(read_state cosign)

# Monotonicity guard: only ever move UP. The tags API is paginated and page 1
# is not ordered by version, so a transient hiccup could report an older
# release as "latest" — without this guard that would auto-publish a
# downgrade as :latest.
NEWEST=$(printf '%s\n%s\n' "$LATEST" "$UNBOUND_VERSION" | sort -V | tail -1)
if [ "$LATEST" != "$UNBOUND_VERSION" ] && [ "$NEWEST" = "$LATEST" ]; then
  action=version
elif [ "$NEW_DEBIAN" != "$OLD_DEBIAN" ] || [ "$NEW_DISTROLESS" != "$OLD_DISTROLESS" ]; then
  if [ "$LATEST" != "$UNBOUND_VERSION" ]; then
    echo "::warning::upstream reported $LATEST, which is not above the pinned $UNBOUND_VERSION — ignoring it and treating this as a revision rebuild" >&2
  fi
  action=revision
else
  action=none
fi

# The sidecar's bases are independent of the resolver's: an Alpine or cosign
# update rebuilds only the sidecar, never the resolver, and vice versa.
if [ "$NEW_ALPINE" != "$OLD_ALPINE" ] || [ "$NEW_COSIGN" != "$OLD_COSIGN" ]; then
  updater_action=revision
else
  updater_action=none
fi

printf 'action=%s\nupdater_action=%s\n' "$action" "$updater_action"
