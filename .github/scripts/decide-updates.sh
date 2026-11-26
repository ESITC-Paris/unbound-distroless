#!/usr/bin/env bash
# Decision logic of the update monitor (upstream-check.yml), kept out of the
# workflow so tests/monitor.sh can exercise it without GitHub.
#
# Inputs (environment): LATEST (newest upstream Unbound version), NEW_DEBIAN,
# NEW_DISTROLESS, NEW_ALPINE, NEW_COSIGN (freshly resolved digests);
# optional RESCAN_RESOLVER, RESCAN_UPDATER (status of the published-image
# rescan, see rescan-decide.sh — empty when the rescan did not complete);
# optional FORCE_REBUILD=none|resolver|sidecar|both (manual dispatch input:
# the recovery path for a release that failed after pushing its immutable
# tag, which release.yml/updater.yml then refuse to re-run);
# optional HOLD=none|resolver|sidecar|both (.github/monitor-hold, read by
# hold.sh): a held image is published by nothing but FORCE_REBUILD, and then
# as a revision of what the repository pins — never as a new version.
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

# Rescan: only `new` asks for a rebuild (a candidate build was scanned clean;
# `waiting` and `pending` publish nothing). Empty means the rescan failed or was not run:
# that must never publish anything (the workflow reports the failure on its
# own), and it must not block a version or base update either. An unknown
# value is a wiring bug — refuse rather than guess.
case "${FORCE_REBUILD:-none}" in
  none|resolver|sidecar|both) ;;
  *) echo "::error::FORCE_REBUILD has unexpected value '$FORCE_REBUILD'" >&2; exit 1 ;;
esac
case "${HOLD:-none}" in
  none|resolver|sidecar|both) ;;
  *) echo "::error::HOLD has unexpected value '$HOLD'" >&2; exit 1 ;;
esac
for v in RESCAN_RESOLVER RESCAN_UPDATER; do
  case "${!v:-}" in
    ""|clean|new|pending|waiting) ;;
    *) echo "::error::$v has unexpected value '${!v}'" >&2; exit 1 ;;
  esac
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
elif [ "${RESCAN_RESOLVER:-}" = new ] || [ "${FORCE_REBUILD:-none}" = resolver ] || [ "${FORCE_REBUILD:-none}" = both ]; then
  # Same base digests, but a candidate built from them no longer has what
  # the gate refuses in the published image (packages published since, e.g.
  # in trixie-security) — or a maintainer asked: rebuild. The
  # revision bump is also what invalidates the package-upgrade layer
  # (IMAGE_REVISION build arg).
  action=revision
else
  action=none
fi

# The sidecar's bases are independent of the resolver's: an Alpine or cosign
# update rebuilds only the sidecar, never the resolver, and vice versa.
if [ "$NEW_ALPINE" != "$OLD_ALPINE" ] || [ "$NEW_COSIGN" != "$OLD_COSIGN" ] \
   || [ "${RESCAN_UPDATER:-}" = new ] || [ "${FORCE_REBUILD:-none}" = sidecar ] || [ "${FORCE_REBUILD:-none}" = both ]; then
  updater_action=revision
else
  updater_action=none
fi

# A hold wins over everything automatic. The maintainer's own rebuild request
# is the one way to publish a held image: it is how the rollback revision is
# cut (docs/operations.md), from the pins as they are in the repository
# (write-state.sh leaves a held image's base digests alone).
held() { [ "${HOLD:-none}" = "$1" ] || [ "${HOLD:-none}" = both ]; }
forced() { [ "${FORCE_REBUILD:-none}" = "$1" ] || [ "${FORCE_REBUILD:-none}" = both ]; }
if held resolver; then
  [ "$action" = none ] || echo "::notice::resolver on hold (.github/monitor-hold): '$action' not published by itself" >&2
  if forced resolver; then action=revision; else action=none; fi
fi
if held sidecar; then
  [ "$updater_action" = none ] || echo "::notice::sidecar on hold (.github/monitor-hold): '$updater_action' not published by itself" >&2
  if forced sidecar; then updater_action=revision; else updater_action=none; fi
fi

printf 'action=%s\nupdater_action=%s\n' "$action" "$updater_action"
