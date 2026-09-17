#!/usr/bin/env bash
# Unit test for the update monitor's decision logic (.github/scripts/decide-updates.sh).
# Runs anywhere: no network, no docker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/.github/scripts/decide-updates.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/versions.env" <<'ENV'
UNBOUND_VERSION=1.26.0
UNBOUND_SHA256=abc
REVISION=3
UPDATER_VERSION=1.0.0
UPDATER_REVISION=0
ENV
cat > "$tmp/.build-state.json" <<'JSON'
{ "debian": "sha256:d1", "distroless": "sha256:s1", "alpine": "sha256:a1", "cosign": "sha256:c1" }
JSON

decide() {  # decide <latest> <debian> <distroless> <alpine> <cosign>
  ( cd "$tmp" && LATEST="$1" NEW_DEBIAN="$2" NEW_DISTROLESS="$3" NEW_ALPINE="$4" NEW_COSIGN="$5" bash "$SCRIPT" )
}

out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
[ "$out" = $'action=none\nupdater_action=none' ] || fail "all unchanged: $out"
pass "nothing changed → none/none"

out=$(decide 1.27.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
grep -qx 'action=version' <<<"$out" || fail "new unbound version: $out"
grep -qx 'updater_action=none' <<<"$out" || fail "new unbound version must not touch the sidecar: $out"
pass "newer unbound → version/none"

out=$(decide 1.25.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
grep -qx 'action=none' <<<"$out" || fail "older upstream must be ignored (monotonicity): $out"
pass "older upstream → none (monotonicity guard)"

out=$(decide 1.26.0 sha256:d2 sha256:s1 sha256:a1 sha256:c1)
grep -qx 'action=revision' <<<"$out" || fail "debian digest change: $out"
grep -qx 'updater_action=none' <<<"$out" || fail "debian digest change must not rebuild the sidecar: $out"
pass "debian base moved → revision/none"

out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a2 sha256:c1)
grep -qx 'action=none' <<<"$out" || fail "alpine change must not rebuild the resolver: $out"
grep -qx 'updater_action=revision' <<<"$out" || fail "alpine digest change: $out"
pass "alpine base moved → none/revision"

out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a1 sha256:c2)
grep -qx 'updater_action=revision' <<<"$out" || fail "cosign digest change: $out"
pass "cosign image moved → none/revision"

out=$(decide 1.27.0 sha256:d2 sha256:s2 sha256:a2 sha256:c2)
[ "$out" = $'action=version\nupdater_action=revision' ] || fail "everything moved: $out"
pass "everything moved → version/revision"

# A state file predating the sidecar keys must count as "changed" once, so
# the first run after this change records them — but never as a resolver change.
printf '{ "debian": "sha256:d1", "distroless": "sha256:s1" }\n' > "$tmp/.build-state.json"
out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
[ "$out" = $'action=none\nupdater_action=revision' ] || fail "legacy state without sidecar keys: $out"
pass "legacy .build-state.json → none/revision"

for v in "" "sha256:d1"; do
  if out=$(decide 1.26.0 "$v" "" sha256:a1 sha256:c1 2>&1); then fail "empty digest was accepted: $out"; fi
done
pass "an empty digest is a hard error, never a bump"

echo "ALL MONITOR TESTS PASSED"
