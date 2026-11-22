#!/usr/bin/env bash
# Unit test for the update monitor's decision logic (.github/scripts/decide-updates.sh).
# Runs anywhere: no network, no docker.
# SC2015: `A && B || fail …` is used as if-then-else on purpose — fail exits.
# SC2016: single-quoted fixtures hold literal $ and backticks on purpose.
# shellcheck disable=SC2015,SC2016
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

# ---------------------------------------------------------------------------
# Published-image rescan: its verdict feeds decide-updates.sh.
cat > "$tmp/.build-state.json" <<'JSON'
{ "debian": "sha256:d1", "distroless": "sha256:s1", "alpine": "sha256:a1", "cosign": "sha256:c1" }
JSON
decide_rescan() {  # decide_rescan <latest> <debian> <resolver-status> <updater-status>
  ( cd "$tmp" && LATEST="$1" NEW_DEBIAN="$2" NEW_DISTROLESS=sha256:s1 NEW_ALPINE=sha256:a1 NEW_COSIGN=sha256:c1 \
      RESCAN_RESOLVER="$3" RESCAN_UPDATER="$4" bash "$SCRIPT" )
}
out=$(decide_rescan 1.26.0 sha256:d1 new "")
[ "$out" = $'action=revision\nupdater_action=none' ] || fail "rescan new (resolver): $out"
out=$(decide_rescan 1.26.0 sha256:d1 "" new)
[ "$out" = $'action=none\nupdater_action=revision' ] || fail "rescan new (sidecar): $out"
pass "rescan finds a fixable vulnerability → revision of that image only"

for s in "" clean pending stuck; do
  out=$(decide_rescan 1.26.0 sha256:d1 "$s" "$s")
  [ "$out" = $'action=none\nupdater_action=none' ] || fail "rescan '$s' must not publish: $out"
done
pass "rescan clean / pending / stuck / unavailable → none/none"

out=$(decide_rescan 1.27.0 sha256:d1 "" "")
grep -qx 'action=version' <<<"$out" || fail "a failed rescan must not hold back a new version: $out"
out=$(decide_rescan 1.27.0 sha256:d1 new "")
grep -qx 'action=version' <<<"$out" || fail "version must win over a rescan revision: $out"
pass "a missing rescan never blocks a version update; version wins over rescan"

if out=$(decide_rescan 1.26.0 sha256:d1 vulnerable "" 2>&1); then fail "unknown rescan status was accepted: $out"; fi
pass "an unknown rescan status is a hard error"

force() {  # force <value>
  ( cd "$tmp" && LATEST=1.26.0 NEW_DEBIAN=sha256:d1 NEW_DISTROLESS=sha256:s1 NEW_ALPINE=sha256:a1 NEW_COSIGN=sha256:c1 \
      FORCE_REBUILD="$1" bash "$SCRIPT" )
}
[ "$(force none)" = $'action=none\nupdater_action=none' ] || fail "rebuild=none: $(force none)"
[ "$(force resolver)" = $'action=revision\nupdater_action=none' ] || fail "rebuild=resolver: $(force resolver)"
[ "$(force sidecar)" = $'action=none\nupdater_action=revision' ] || fail "rebuild=sidecar: $(force sidecar)"
[ "$(force both)" = $'action=revision\nupdater_action=revision' ] || fail "rebuild=both: $(force both)"
if out=$(force all 2>&1); then fail "unknown rebuild value accepted: $out"; fi
out=$( cd "$tmp" && LATEST=1.26.0 NEW_DEBIAN=sha256:d1 NEW_DISTROLESS=sha256:s1 NEW_ALPINE=sha256:a1 NEW_COSIGN=sha256:c1 \
  FORCE_REBUILD=both RESCAN_RESOLVER=pending RESCAN_UPDATER=stuck bash "$SCRIPT" )
[ "$out" = $'action=revision\nupdater_action=revision' ] || fail "a forced rebuild must override pending/stuck: $out"
out=$( cd "$tmp" && LATEST=1.26.0 NEW_DEBIAN=sha256:d1 NEW_DISTROLESS=sha256:s1 NEW_ALPINE=sha256:a1 NEW_COSIGN=sha256:c1 \
  RESCAN_RESOLVER=blocked RESCAN_UPDATER=blocked bash "$SCRIPT" )
[ "$out" = $'action=none\nupdater_action=none' ] || fail "blocked must never publish: $out"
pass "manual rebuild input (recovery path) → revision of the named image(s), also over pending/stuck; blocked never publishes"

# rescan-decide.sh: same policy as the release gates, loop guard.
RESCAN="$HERE/.github/scripts/rescan-decide.sh"
D1=sha256:1111111111111111111111111111111111111111111111111111111111111111
D2=sha256:2222222222222222222222222222222222222222222222222222222222222222
# report <file> <arch> <digest> <results-json>: a trimmed Trivy JSON report,
# same shape as `trivy image --format json` 0.70 (checked against the live
# images on 2026-11-21).
report() {
  cat > "$tmp/$1" <<EOF
{ "SchemaVersion": 2, "ArtifactName": "ghcr.io/esitc-paris/img@$3", "ArtifactType": "container_image",
  "Metadata": { "ImageConfig": { "architecture": "$2" }, "RepoDigests": ["ghcr.io/esitc-paris/img@$3"] },
  "Results": $4 }
EOF
}
OS_CLEAN='[{"Target": "img (debian 13.7)", "Class": "os-pkgs", "Type": "debian"}]'
OS_HIGH='[{"Target": "img (debian 13.7)", "Class": "os-pkgs", "Type": "debian", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-1", "PkgName": "libssl3t64", "InstalledVersion": "3.5.1-1", "FixedVersion": "3.5.1-2", "Status": "fixed", "Severity": "HIGH"}]}]'
OS_UNFIXED='[{"Target": "img (debian 13.7)", "Class": "os-pkgs", "Type": "debian", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-9", "PkgName": "libc6", "InstalledVersion": "2.41-1", "Status": "affected", "Severity": "CRITICAL"},
  {"VulnerabilityID": "CVE-2026-8", "PkgName": "libc6", "InstalledVersion": "2.41-1", "FixedVersion": "2.41-2", "Status": "fixed", "Severity": "MEDIUM"}]}]'
COSIGN_HIGH='[{"Target": "img (alpine 3.24.4)", "Class": "os-pkgs", "Type": "alpine"},
  {"Target": "usr/local/bin/cosign", "Class": "lang-pkgs", "Type": "gobinary", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-2", "PkgName": "golang.org/x/crypto", "InstalledVersion": "v0.50.0", "FixedVersion": "0.55.0", "Status": "fixed", "Severity": "HIGH"}]}]'
COSIGN_CRIT='[{"Target": "usr/local/bin/cosign", "Class": "lang-pkgs", "Type": "gobinary", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-3", "PkgName": "stdlib", "InstalledVersion": "v1.25.0", "FixedVersion": "1.25.9", "Status": "fixed", "Severity": "CRITICAL"}]}]'
APK_HIGH='[{"Target": "img (alpine 3.24.4)", "Class": "os-pkgs", "Type": "alpine", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-4", "PkgName": "krb5-libs", "InstalledVersion": "1.22.2-r0", "FixedVersion": "1.22.3-r0", "Status": "fixed", "Severity": "HIGH"}]}]'

# The resolver's base layers; a finding whose Layer.DiffID is one of them
# needs a new base digest, not a rebuild.
BASEL=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' "$BASEL" sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc > "$tmp/base.txt"
export BASE_DIFFIDS_FILE="$tmp/base.txt" NOW=1800000000
OS_BASE='[{"Target": "img (debian 13.7)", "Class": "os-pkgs", "Type": "debian", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-5", "PkgName": "libc6", "InstalledVersion": "2.41-1", "FixedVersion": "2.41-2", "Status": "fixed", "Severity": "HIGH",
   "Layer": {"DiffID": "'"$BASEL"'"}}]}]'
NO_ID='[{"Target": "img (debian 13.7)", "Class": "os-pkgs", "Type": "debian", "Vulnerabilities": [
  {"PkgName": "libssl3t64", "FixedVersion": "3.5.1-2", "Severity": "HIGH"}]}]'
NASTY='[{"Target": "img (debian 13.7)", "Class": "os-pkgs", "Type": "debian", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-6\nstatus=new", "PkgName": "lib$(x)`y`", "FixedVersion": "1", "Severity": "HIGH"}]}]'

rescan() {  # rescan <policy> <digest> <amd64-results> [<arm64-results>] → $out, $rc
  report a.json amd64 "$2" "$3"
  report b.json arm64 "$2" "${4:-$3}"
  rc=0
  out=$(cd "$tmp" && POLICY="$1" DIGEST="$2" STATE_KEY="rescan_$1" bash "$RESCAN" a.json b.json 2>&1) || rc=$?
}
st() { sed -n 's/^status=//p' <<<"$out"; }
setstate() {  # setstate <python dict literal>: replace the rescan keys of the state
  python3 - "$tmp/.build-state.json" "$1" <<'PY'
import ast, json, sys
p = sys.argv[1]
s = {k: v for k, v in json.load(open(p)).items() if not k.startswith("rescan_")}
s.update(ast.literal_eval(sys.argv[2]))
json.dump(s, open(p, "w"), indent=2)
PY
}

rescan resolver "$D1" "$OS_CLEAN"
[ "$rc" = 0 ] && [ "$(st)" = clean ] || fail "clean resolver: rc=$rc $out"
grep -qx 'vulns=' <<<"$out" || fail "clean must have an empty fingerprint: $out"
rescan resolver "$D1" "$OS_UNFIXED"
[ "$(st)" = clean ] || fail "unfixed CRITICAL and fixed MEDIUM are outside the gate: $out"
rescan resolver "$D1" 'null'
[ "$rc" = 0 ] && [ "$(st)" = clean ] || fail "Trivy's \"Results\": null (nothing found) → clean: rc=$rc $out"
pass "rescan: clean, Results null, unfixed or below-HIGH findings → clean (ignore-unfixed, CRITICAL/HIGH)"

rescan resolver "$D1" "$OS_CLEAN" "$OS_HIGH"
[ "$(st)" = new ] || fail "a fixable HIGH on arm64 only must count: $out"
grep -qx 'count=1' <<<"$out" || fail "count: $out"
grep -q '^summary=CVE-2026-1 (libssl3t64)$' <<<"$out" || fail "summary: $out"
FP=$(sed -n 's/^vulns=//p' <<<"$out")
[[ "$FP" =~ ^[0-9a-f]{16}$ ]] || fail "fingerprint format: $FP"
rescan resolver "$D1" "$OS_HIGH"
[ "$(sed -n 's/^vulns=//p' <<<"$out")" = "$FP" ] || fail "fingerprint must not depend on the platform it was found on"
pass "rescan: fixable HIGH on either platform → new, stable fingerprint"

rescan updater "$D1" "$COSIGN_HIGH"
[ "$(st)" = clean ] || fail "HIGH in the vendored cosign is exempt from the sidecar gate: $out"
rescan resolver "$D1" "$COSIGN_HIGH"
[ "$(st)" = new ] || fail "the cosign exemption must apply to the sidecar only: $out"
rescan updater "$D1" "$APK_HIGH"
[ "$(st)" = new ] || fail "HIGH in an Alpine package fails the sidecar gate and a rebuild fixes it: $out"
pass "rescan: sidecar two-level policy (HIGH except vendored cosign, CRITICAL everywhere)"

rescan updater "$D1" "$COSIGN_CRIT"
[ "$(st)" = blocked ] || fail "CRITICAL in the vendored cosign: a rebuild cannot fix it → blocked: $out"
grep -q 'needs a new cosign release' <<<"$out" || fail "blocked must say why: $out"
rescan resolver "$D1" "$OS_BASE"
[ "$(st)" = blocked ] || fail "finding in a distroless base layer → blocked: $out"
grep -q 'needs a new base digest' <<<"$out" && grep -q '^reason=.' <<<"$out" || fail "blocked must say why: $out"
rescan resolver "$D1" "$OS_BASE" "$OS_HIGH"
[ "$(st)" = new ] || fail "a rebuild-fixable finding next to a base one → new: $out"
[ "$(sed -n 's/^vulns=//p' <<<"$out")" = "$FP" ] || fail "the fingerprint must cover the rebuild-fixable findings only"
grep -qx 'count=2' <<<"$out" || fail "count covers both kinds: $out"
pass "rescan: findings a rebuild cannot fix (vendored cosign CRITICAL, distroless base layer) → blocked, never a revision"

# Loop guard. The record names the digest a rebuild was triggered from, the
# finding set it was triggered for, and when.
setstate "{'rescan_resolver_digest': '$D1', 'rescan_resolver_vulns': '$FP', 'rescan_resolver_at': '$((NOW - 3600))'}"
rescan resolver "$D1" "$OS_HIGH"
[ "$(st)" = pending ] || fail "same digest as the recorded attempt, 1 h ago → pending: $out"
rescan resolver "$D2" "$OS_HIGH"
[ "$(st)" = stuck ] || fail "rebuilt (new digest), same findings → stuck: $out"
grep -q '^reason=One rebuild was published' <<<"$out" || fail "stuck must say why: $out"
rescan resolver "$D2" "$APK_HIGH"
[ "$(st)" = new ] || fail "rebuilt, different findings → new attempt: $out"
rescan resolver "$D2" "$OS_CLEAN"
[ "$(st)" = clean ] || fail "rebuilt and clean → clean: $out"
rescan updater "$D2" "$OS_HIGH"
[ "$(st)" = new ] || fail "the resolver's record must not guard the sidecar: $out"
pass "rescan loop guard: pending on the same digest, stuck after one rebuild, new on a new finding set"

setstate "{'rescan_resolver_digest': '$D1', 'rescan_resolver_vulns': '$FP', 'rescan_resolver_at': '$((NOW - 7 * 3600))'}"
rescan resolver "$D1" "$OS_HIGH"
[ "$(st)" = stuck ] || fail "a triggered rebuild unpublished after 7 h → stuck, not pending forever: $out"
grep -q 'not been published within 6 h' <<<"$out" || fail "expired pending must say why: $out"
setstate "{'rescan_resolver_digest': '$D1', 'rescan_resolver_vulns': '$FP'}"
rescan resolver "$D1" "$OS_HIGH"
[ "$(st)" = stuck ] || fail "a record without a time cannot be pending forever: $out"
pass "rescan: pending expires into stuck after PENDING_HOURS (and a record without a time never pends)"
setstate "{}"

rescan resolver "$D1" "$NASTY"
[ "$(st)" = new ] || fail "nasty names: $out"
[ "$(wc -l <<<"$out")" -eq 5 ] || fail "summary must stay on one line: $out"
grep -q '\$\|`' <<<"$(sed -n 's/^summary=//p' <<<"$out")" && fail "shell metacharacters must be stripped: $out"
pass "rescan: values for \$GITHUB_OUTPUT are one line, metacharacters stripped"

rescan resolver "$D1" "$NO_ID"
[ "$rc" = 1 ] || fail "a finding without VulnerabilityID must be an error, got rc=$rc: $out"
cp "$tmp/.build-state.json" "$tmp/state.bak"; printf '{ "debian": ' > "$tmp/.build-state.json"
rescan resolver "$D1" "$OS_CLEAN"
[ "$rc" = 1 ] || fail "a corrupt .build-state.json must be an error, got rc=$rc: $out"
printf '[]\n' > "$tmp/.build-state.json"
rescan resolver "$D1" "$OS_CLEAN"
[ "$rc" = 1 ] || fail "a .build-state.json that is not an object must be an error, got rc=$rc: $out"
cp "$tmp/state.bak" "$tmp/.build-state.json"
rescan resolver "$D1" "$OS_CLEAN"; report b.json amd64 "$D1" "$OS_CLEAN"
rc=0; out=$(cd "$tmp" && POLICY=resolver DIGEST="$D1" STATE_KEY=rescan_resolver bash "$RESCAN" a.json b.json 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "a missing platform must be an error, got rc=$rc: $out"
rescan resolver "$D1" "$OS_CLEAN"
rc=0; out=$(cd "$tmp" && POLICY=resolver DIGEST="$D2" STATE_KEY=rescan_resolver bash "$RESCAN" a.json b.json 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "a report about another digest must be an error, got rc=$rc: $out"
rc=0; out=$(cd "$tmp" && BASE_DIFFIDS_FILE="" POLICY=resolver DIGEST="$D1" STATE_KEY=rescan_resolver bash "$RESCAN" a.json b.json 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "the resolver policy without base layers must be an error, got rc=$rc: $out"
printf 'FATAL: DB download failed\n' > "$tmp/a.json"
rc=0; out=$(cd "$tmp" && POLICY=resolver DIGEST="$D1" STATE_KEY=rescan_resolver bash "$RESCAN" a.json b.json 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "an unreadable report must be an error, got rc=$rc: $out"
rc=0; out=$(cd "$tmp" && POLICY=resolver DIGEST="$D1" STATE_KEY=rescan_resolver bash "$RESCAN" "$tmp/missing.json" 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "a missing report must be an error, got rc=$rc: $out"
pass "rescan: no ID, corrupt state, missing platform or base list, wrong digest, unreadable report → error, never a verdict"

# write-state.sh: the commit step's rewrite of .build-state.json.
WRITE="$HERE/.github/scripts/write-state.sh"
printf '{\n  "debian": "sha256:d1",\n  "distroless": "sha256:s1",\n  "alpine": "sha256:a1",\n  "cosign": "sha256:c1"\n}\n' > "$tmp/.build-state.json"
cp "$tmp/.build-state.json" "$tmp/expected.json"
write() { ( cd "$tmp" && NEW_DEBIAN=sha256:d1 NEW_DISTROLESS=sha256:s1 NEW_ALPINE=sha256:a1 NEW_COSIGN=sha256:c1 "$@" bash "$WRITE" ); }
write env ACTION=revision UPDATER_ACTION=none
cmp -s "$tmp/.build-state.json" "$tmp/expected.json" || fail "unchanged state must be byte-identical: $(cat "$tmp/.build-state.json")"
pass "write-state: same digests, no rescan → byte-identical file"

write env ACTION=revision UPDATER_ACTION=none RESCAN_RESOLVER=new RESCAN_RESOLVER_DIGEST="$D1" RESCAN_RESOLVER_VULNS="$FP" \
  RESCAN_UPDATER=new RESCAN_UPDATER_DIGEST="$D2" RESCAN_UPDATER_VULNS="$FP"
python3 - "$tmp/.build-state.json" "$D1" "$FP" <<'PY' || fail "record written for the published image only: $(cat "$tmp/.build-state.json")"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["rescan_resolver_digest"] == sys.argv[2] and s["rescan_resolver_vulns"] == sys.argv[3]
assert "rescan_updater_digest" not in s, "sidecar not published in this commit: no record"
assert s["rescan_resolver_at"] == "1800000000", s.get("rescan_resolver_at")
PY
pass "write-state: the loop-guard record is written only for an image this commit publishes"

write env ACTION=none UPDATER_ACTION=revision NEW_ALPINE=sha256:a2 RESCAN_RESOLVER=pending
python3 - "$tmp/.build-state.json" "$D1" <<'PY' || fail "existing keys must survive: $(cat "$tmp/.build-state.json")"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["alpine"] == "sha256:a2" and s["rescan_resolver_digest"] == sys.argv[2]
PY
pass "write-state: unrelated keys (an earlier record) are kept, digests updated"

if out=$(write env ACTION=revision RESCAN_RESOLVER=new RESCAN_RESOLVER_DIGEST="" RESCAN_RESOLVER_VULNS="$FP" 2>&1); then
  fail "a record without a digest was accepted: $out"
fi
pass "write-state: a malformed record is refused, nothing half-written is committed"

# ---------------------------------------------------------------------------
# registry.sh: present / absent / error, never a guess. curl is faked.
REG="$HERE/.github/scripts/registry.sh"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Canned registry. Files in $FAKE_DIR: token_fail (token request fails),
# code (HTTP status of the manifest HEAD, default 200), calls (log).
T="$FAKE_DIR"; out=""; hdr=""; fmt=""; f=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -fsS) f=1; shift ;;
    -H|-m|--retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >> "$T/calls"
case "$url" in
  *token*)
    [ -f "$T/token_fail" ] && exit 22
    echo '{"token":"t0k"}' > "$out" ;;
  */manifests/*)
    # Per-tag overrides: code_<tag>, digest_<tag> (64 hex).
    tag=${url##*/}
    code=$(cat "$T/code_$tag" 2>/dev/null || cat "$T/code" 2>/dev/null || echo 200)
    dig=$(cat "$T/digest_$tag" 2>/dev/null || printf 'a%.0s' $(seq 64))
    printf 'HTTP/2 %s\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$code" "$dig" > "$hdr"
    printf '%s' "$code" ;;
  *) exit 99 ;;
esac
FAKE
chmod +x "$tmp/bin/curl"
reg() { rc=0; out=$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" bash "$REG" "$@" 2>&1) || rc=$?; }

reg state esitcparis/unbound-distroless 1.26.2-r4
[ "$rc" = 0 ] && [ "$out" = present ] || fail "200 → present: rc=$rc $out"
grep -q '^https://auth.docker.io/token?service=registry.docker.io&scope=repository:esitcparis/unbound-distroless:pull$' "$tmp/calls" \
  || fail "Docker Hub token URL: $(cat "$tmp/calls")"
grep -q '^https://registry-1.docker.io/v2/esitcparis/unbound-distroless/manifests/1.26.2-r4$' "$tmp/calls" \
  || fail "Docker Hub manifest URL: $(cat "$tmp/calls")"
echo 404 > "$tmp/code"; rm -f "$tmp/calls"
reg state ghcr.io/esitc-paris/unbound-distroless 1.26.2-r5
[ "$rc" = 0 ] && [ "$out" = absent ] || fail "404 → absent: rc=$rc $out"
grep -q '^https://ghcr.io/v2/esitc-paris/unbound-distroless/manifests/1.26.2-r5$' "$tmp/calls" || fail "GHCR manifest URL: $(cat "$tmp/calls")"
pass "registry: 200 → present, 404 → absent, on both registries"

for code in 401 403 429 500 503 000; do
  echo "$code" > "$tmp/code"
  reg state esitcparis/unbound-distroless 1.26.2-r5
  [ "$rc" = 1 ] || fail "HTTP $code must be an error, never 'absent': rc=$rc $out"
done
rm -f "$tmp/code"; touch "$tmp/token_fail"
reg state esitcparis/unbound-distroless 1.26.2-r5
[ "$rc" = 1 ] || fail "a failed token request must be an error: rc=$rc $out"
rm -f "$tmp/token_fail"
pass "registry: auth refusal, rate limit, outage, token failure → error, never 'absent'"

reg digest ghcr.io/esitc-paris/unbound-distroless latest
[ "$rc" = 0 ] && [ "$out" = "sha256:$(printf 'a%.0s' $(seq 64))" ] || fail "digest: rc=$rc $out"
echo 404 > "$tmp/code"
reg digest ghcr.io/esitc-paris/unbound-distroless latest
[ "$rc" = 1 ] || fail "digest of an absent tag must be an error: rc=$rc $out"
rm -f "$tmp/code"
for bad in "state esitcparis/x ../latest" "state quay.io/x/y 1" "state x 1" "state esitcparis/x 1;rm" "digest esitcparis/X 1"; do
  # shellcheck disable=SC2086
  reg $bad
  [ "$rc" = 1 ] || fail "invalid input accepted: $bad → $out"
done
pass "registry: digest lookup; invalid image, tag or registry refused"

# refuse-published.sh: the release guard built on registry.sh.
REFUSE="$HERE/.github/scripts/refuse-published.sh"
refuse() { rc=0; out=$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" REBUILD_TARGET=resolver bash "$REFUSE" "$@" 2>&1) || rc=$?; }
echo 404 > "$tmp/code"
refuse 1.26.2-r5 esitcparis/unbound-distroless ghcr.io/esitc-paris/unbound-distroless
[ "$rc" = 0 ] || fail "absent everywhere must pass: rc=$rc $out"
echo 200 > "$tmp/code"
refuse 1.26.2-r4 esitcparis/unbound-distroless ghcr.io/esitc-paris/unbound-distroless
[ "$rc" = 1 ] || fail "a published tag must be refused: rc=$rc $out"
if ! grep -q 'never re-pushed' <<<"$out" || ! grep -q 'rebuild=resolver' <<<"$out"; then
  fail "refusal must say why and how to recover: $out"
fi
echo 503 > "$tmp/code"
refuse 1.26.2-r5 esitcparis/unbound-distroless
[ "$rc" = 1 ] || fail "an unanswering registry must stop the release: rc=$rc $out"
rm -f "$tmp/code"
pass "release guard: absent → go; present or unknown in any registry → refuse, with the recovery path"

# release-facts.sh: what is published for one release.
FACTS="$HERE/.github/scripts/release-facts.sh"
facts() { rc=0; out=$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" bash "$FACTS" 1.26.2-r5 esitcparis/x ghcr.io/esitc-paris/x latest 1 1.26 1.26.2 2>&1) || rc=$?; }
rm -f "$tmp"/code* "$tmp"/digest_*
facts
[ "$rc" = 0 ] && grep -qx 'mutable_ok=yes' <<<"$out" && grep -qx "hub_digest=sha256:$(printf 'a%.0s' $(seq 64))" <<<"$out" || fail "all at one digest: $out"
printf 'b%.0s' $(seq 64) > "$tmp/digest_latest"
facts
grep -qx 'mutable_ok=no' <<<"$out" || fail "latest elsewhere → mutable_ok=no: $out"
rm -f "$tmp/digest_latest"; echo 404 > "$tmp/code_1.26.2-r5"
facts
grep -qx 'hub_digest=absent' <<<"$out" && grep -qx 'mutable_ok=no' <<<"$out" || fail "absent immutable tag: $out"
echo 503 > "$tmp/code_1"
facts
[ "$rc" = 0 ] || fail "mutable tags are not looked up when the immutable one is absent: $out"
rm -f "$tmp/code_1.26.2-r5"
facts
[ "$rc" = 1 ] || fail "a registry error on a mutable tag must be an error, not 'behind': rc=$rc $out"
rm -f "$tmp"/code*
pass "release-facts: digests, mutable tags in place or not, absent; a registry error is an error"

# release-mode.sh: full / resume / done / refuse.
MODE="$HERE/.github/scripts/release-mode.sh"
DA=sha256:$(printf 'a%.0s' $(seq 64)); DB=sha256:$(printf 'b%.0s' $(seq 64))
mode() {  # mode <hub> <ghcr> <signed> <current> <mutable_ok> <release_exists>
  rc=0; out=$(HUB_DIGEST=$1 GHCR_DIGEST=$2 SIGNED=$3 CURRENT=$4 MUTABLE_OK=$5 RELEASE_EXISTS=$6 REBUILD_TARGET=resolver bash "$MODE" 2>&1) || rc=$?
}
mode absent absent no yes no no;      [ "$rc" = 0 ] && grep -qx 'mode=full' <<<"$out" || fail "nothing published → full: $out"
mode "$DA" "$DA" yes yes no no;       [ "$rc" = 0 ] && grep -qx 'mode=resume' <<<"$out" && grep -qx "digest=$DA" <<<"$out" || fail "signed, tail missing, current → resume: $out"
mode "$DA" "$DA" yes yes yes no;      grep -qx 'mode=resume' <<<"$out" || fail "release missing → resume: $out"
mode "$DA" "$DA" yes yes no yes;      grep -qx 'mode=resume' <<<"$out" || fail "mutable tags behind on the current revision → resume: $out"
mode "$DA" "$DA" yes yes yes yes;     grep -qx 'mode=done' <<<"$out" && grep -q 'duplicate dispatch' <<<"$out" || fail "fully published → done, said so: $out"
mode "$DA" "$DA" yes no no yes;       grep -qx 'mode=done' <<<"$out" || fail "an older revision, released, latest moved on → done (nothing moves): $out"
pass "release-mode: full when absent, resume a signed current tail, nothing for a duplicate"
mode "$DA" "$DA" yes no no no;        [ "$rc" = 1 ] && grep -q 'move latest backwards' <<<"$out" || fail "resuming a non-current tag must be refused: $out"
mode "$DA" "$DA" no yes no no;        [ "$rc" = 1 ] && grep -q 'rebuild=resolver' <<<"$out" || fail "unsigned immutable tag → refused with the fix: $out"
mode "$DA" absent yes yes no no;      [ "$rc" = 1 ] || fail "one registry only → refused: $out"
mode "$DA" "$DB" yes yes no no;       [ "$rc" = 1 ] || fail "different digests → refused: $out"
mode "$DA" "$DA" maybe yes no no;     [ "$rc" = 1 ] || fail "bad input accepted: $out"
pass "release-mode: never resumes an old tag (latest would move back), an unsigned one, or a split one"

# release-health.sh: is the current release really out?
HEALTH="$HERE/.github/scripts/release-health.sh"
health() { rc=0; out=$(TAG_IN_GIT=$1 COMPLETE=$2 RUNS=$3 bash "$HEALTH" 2>&1) || rc=$?; h=$(sed -n 's/^health=//p' <<<"$out"); }
health no no "";                                  [ "$h" = untagged ] || fail "untagged: $out"
health yes yes "completed success";               [ "$h" = complete ] || fail "complete: $out"
health yes no "queued ";                          [ "$h" = in-flight ] || fail "queued → wait: $out"
health yes no $'in_progress \ncompleted cancelled'; [ "$h" = in-flight ] || fail "running → wait: $out"
health yes no "";                                 [ "$h" = redispatch ] || fail "never ran (dispatch lost) → redispatch: $out"
health yes no "completed cancelled";              [ "$h" = redispatch ] || fail "cancelled in the queue → redispatch: $out"
health yes no $'completed failure\ncompleted cancelled'; [ "$h" = redispatch ] || fail "2 runs → one more: $out"
health yes no $'completed failure\ncompleted failure\ncompleted cancelled'; [ "$h" = give-up ] || fail "3 runs → issue: $out"
health yes no "exploded x";                       [ "$rc" = 1 ] || fail "unknown run status accepted: $out"
pass "release-health: lost / cancelled / timed-out release → re-dispatched, at most 3 runs, then an issue; running → wait"

# Wiring: every rescan output `check` reads exists, and every step output a
# job output names comes from a step that exists (a typo would silently read
# as "" — i.e. "no verdict" — forever).
python3 - "$HERE/.github/workflows/upstream-check.yml" <<'PY' || fail "upstream-check.yml wiring"
import re, sys
y = open(sys.argv[1]).read()
rescan = y[y.index("\n  rescan:\n"):y.index("\n  code-scanning:\n")]
outs = dict(re.findall(r"^      (\w+): \$\{\{ steps\.(\w+)\.outputs\.\w+ \}\}$", rescan, re.M))
ids = set(re.findall(r"^        id: (\w+)$", rescan, re.M))
assert outs, "no rescan outputs found"
for o, step in outs.items():
    assert step in ids, f"rescan output {o} reads missing step {step}"
used = set(re.findall(r"needs\.rescan\.outputs\.(\w+)", y))
missing = used - set(outs)
assert not missing, f"check reads undefined rescan outputs {missing}"
for k in ("verdict", "resolver", "updater", "resolver_digest", "resolver_vulns", "updater_digest", "updater_vulns"):
    assert k in used, f"rescan output {k} is never read"
PY
pass "upstream-check.yml: rescan outputs and their consumers are wired"

echo "ALL MONITOR TESTS PASSED"
