#!/usr/bin/env bash
# Decision logic of the published-image rescan (upstream-check.yml, job
# `rescan`), kept out of the workflow so tests/monitor.sh can exercise it.
#
# The rescan applies the SAME policy as the release gate that will judge the
# rebuild. Any difference means a rebuild the gate refuses, or one it accepts
# that the rescan then flags again — a loop either way:
#   resolver  (release.yml): CRITICAL+HIGH with a fix, whole image.
#   updater   (updater.yml): CRITICAL with a fix, whole image; HIGH with a fix
#             everywhere except the vendored usr/local/bin/cosign binary.
# The Trivy reports must be produced with --severity CRITICAL,HIGH
# --ignore-unfixed and WITHOUT --skip-files: the cosign exemption is applied
# here, so that one scan per platform serves both levels.
#
# A finding only asks for a rebuild if a rebuild can fix it:
#   * resolver: a finding in a layer of the distroless base (BASE_DIFFIDS_FILE)
#     cannot — the final stage has no package manager; only a new base digest
#     can, and the monitor already rebuilds when that digest moves;
#   * updater: a CRITICAL in the vendored cosign binary cannot — the binary is
#     copied from a digest-pinned upstream image; only a new cosign release
#     can, and the monitor already rebuilds when that digest moves.
#   (Alpine packages from the sidecar's base CAN be fixed by a rebuild: its
#   `apk upgrade` layer takes whatever Alpine has published.)
# Findings that a rebuild cannot fix yield `blocked`, never a revision.
#
# Inputs (environment):
#   POLICY            resolver | updater
#   DIGEST            index digest of the published image that was scanned
#   STATE_KEY         prefix of the loop-guard keys in .build-state.json
#                     (rescan_resolver | rescan_updater)
#   EXPECT_ARCHS      architectures that must all be covered (default
#                     "amd64 arm64": the release gate scans both natively)
#   BASE_DIFFIDS_FILE resolver only, required: the base image's layer DiffIDs,
#                     one per line, all platforms
#   NOW               epoch seconds (default: the current time)
#   PENDING_HOURS     how long a triggered rebuild may stay unpublished
#                     before it is reported (default 6; a release takes ~1 h)
# Arguments: one Trivy JSON report per platform.
# Files: .build-state.json in the current directory (loop-guard record).
#
# Output (stdout, KEY=VALUE lines for $GITHUB_OUTPUT, values sanitised to
# one line of printable characters):
#   status=clean    nothing the gate would refuse
#   status=new      rebuild-fixable findings, no rebuild tried for them yet
#   status=pending  a rebuild was triggered from this very digest less than
#                   PENDING_HOURS ago and is not published yet: wait
#   status=stuck    a rebuild was published and still carries exactly the
#                   same findings, or the triggered rebuild was never
#                   published within PENDING_HOURS: report, stop
#   status=blocked  only findings a rebuild cannot fix: report, no rebuild
#   vulns=<16 hex>  fingerprint of the rebuild-fixable set (empty if none)
#   count=<n>       number of distinct findings (all kinds)
#   summary=<text>  "ID (package) [kind]", truncated, for the issue body
#   reason=<text>   one sentence for the issue body (stuck / blocked)
#
# Loop guard: at most one rebuild per (published digest, finding set). The
# record (<STATE_KEY>_digest/_vulns/_at) is written by write-state.sh only
# when the monitor publishes the rebuild this script asked for.
# A malformed report or state file is an error (exit 1): a scanner outage
# must fail the run visibly, never read as "clean" or as "rebuild".
set -euo pipefail

: "${POLICY:?}" "${DIGEST:?}" "${STATE_KEY:?}"
export EXPECT_ARCHS="${EXPECT_ARCHS:-amd64 arm64}"
export PENDING_HOURS="${PENDING_HOURS:-6}"
NOW="${NOW:-$(date +%s)}"; export NOW
export BASE_DIFFIDS_FILE="${BASE_DIFFIDS_FILE:-}"
case "$POLICY" in resolver|updater) ;; *) echo "::error::unknown POLICY '$POLICY'" >&2; exit 1 ;; esac
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::DIGEST '$DIGEST' is not a sha256 digest" >&2; exit 1; }
[[ "$NOW" =~ ^[0-9]+$ && "$PENDING_HOURS" =~ ^[0-9]+$ ]] || { echo "::error::NOW and PENDING_HOURS must be integers" >&2; exit 1; }
[ $# -gt 0 ] || { echo "::error::no Trivy report given" >&2; exit 1; }

python3 - "$@" <<'PY'
import hashlib, json, os, re, sys

policy, digest, key = os.environ["POLICY"], os.environ["DIGEST"], os.environ["STATE_KEY"]
expect = set(os.environ["EXPECT_ARCHS"].split())
now, pending_hours = int(os.environ["NOW"]), int(os.environ["PENDING_HOURS"])

def fail(msg):
    print(f"::error::rescan: {msg}", file=sys.stderr)
    sys.exit(1)

base = set()
if policy == "resolver":
    path = os.environ["BASE_DIFFIDS_FILE"]
    if not path:
        fail("BASE_DIFFIDS_FILE is required for the resolver policy")
    try:
        base = {l.strip() for l in open(path) if l.strip()}
    except OSError as e:
        fail(f"base layer list unreadable ({e})")
    if not base or not all(re.fullmatch(r"sha256:[0-9a-f]{64}", d) for d in base):
        fail(f"{path}: not a list of layer DiffIDs")

fixable, other, archs = set(), set(), set()
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"{path}: unreadable Trivy report ({e})")
    if not isinstance(report, dict) or report.get("SchemaVersion") != 2:
        fail(f"{path}: not a Trivy JSON report (SchemaVersion 2)")
    meta = report.get("Metadata") or {}
    # The report must be about the digest we resolved, not whatever a tag
    # pointed at a moment later.
    if digest not in report.get("ArtifactName", "") and not any(
        d.endswith("@" + digest) for d in meta.get("RepoDigests") or []
    ):
        fail(f"{path}: report is not about {digest}")
    arch = (meta.get("ImageConfig") or {}).get("architecture")
    if not arch:
        fail(f"{path}: no architecture in the report")
    archs.add(arch)
    for result in report.get("Results") or []:
        target = result.get("Target", "")
        for v in result.get("Vulnerabilities") or []:
            sev = v.get("Severity")
            # Re-applied defensively: the scan flags already filter, but the
            # verdict must not depend on them having been passed.
            if sev not in ("CRITICAL", "HIGH") or not v.get("FixedVersion"):
                continue
            if policy == "updater" and sev == "HIGH" and target == "usr/local/bin/cosign":
                continue
            vid, pkg = v.get("VulnerabilityID"), v.get("PkgName")
            if not vid or not pkg:
                fail(f"{path}: a finding without VulnerabilityID/PkgName in {target!r}")
            # Package and ID only: installed versions and targets change from
            # one rebuild to the next, an unfixed finding does not.
            item = f"{vid} ({pkg})"
            if policy == "updater" and target == "usr/local/bin/cosign":
                other.add(item + " [vendored cosign: needs a new cosign release]")
            elif policy == "resolver" and (v.get("Layer") or {}).get("DiffID") in base:
                other.add(item + " [distroless base: needs a new base digest]")
            else:
                fixable.add(item)

if archs != expect:
    fail(f"reports cover {sorted(archs)}, expected {sorted(expect)}")

try:
    with open(".build-state.json") as f:
        state = json.load(f)
    if not isinstance(state, dict):
        raise ValueError("not a JSON object")
except (OSError, ValueError) as e:
    fail(f".build-state.json unreadable ({e})")

items = sorted(fixable)
fp = hashlib.sha256("\n".join(items).encode()).hexdigest()[:16] if items else ""
reason = ""
rec_digest, rec_vulns = state.get(f"{key}_digest"), state.get(f"{key}_vulns")
try:
    rec_at = int(state.get(f"{key}_at", 0))
except (TypeError, ValueError):
    rec_at = 0
if items and rec_digest == digest:
    age_h = (now - rec_at) // 3600
    if rec_at and age_h < pending_hours:
        status = "pending"
    else:
        status = "stuck"
        reason = (f"A rebuild was triggered from this digest {age_h if rec_at else '?'} h ago "
                  f"and has not been published within {pending_hours} h: the release run was lost, "
                  "failed or is blocked (see the release workflow's runs and issues).")
elif items and rec_vulns == fp:
    status = "stuck"
    reason = ("One rebuild was published for exactly these findings and they are still there: "
              "the fix is not in the distribution yet, or the scanner and the distribution disagree.")
elif items:
    status = "new"
elif other:
    status = "blocked"
    reason = ("Every finding is in a component a rebuild cannot change; the monitor rebuilds by itself "
              "when that component's pinned digest moves. Nothing to do unless that takes too long.")
else:
    status = "clean"

def clean(text, limit=900):
    # One line of printable text: these values go to $GITHUB_OUTPUT.
    text = re.sub(r"[^\w .,:;()+/@~\[\]'-]", "?", text)
    return text if len(text) <= limit else text[:limit] + " ..."

listed = items + sorted(other)
print(f"status={status}")
print(f"vulns={fp}")
print(f"count={len(listed)}")
print(f"summary={clean(', '.join(listed))}")
print(f"reason={clean(reason)}")
PY
