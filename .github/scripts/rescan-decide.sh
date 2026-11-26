#!/usr/bin/env bash
# Decision logic for the published-image rescan (upstream-check.yml), kept
# out of the workflow so tests/monitor.sh can exercise it without GitHub.
#
# The monitor rebuilds on a new Unbound version or a moved base digest. A fix
# that lands in trixie-security or in Alpine without the base image being
# rebuilt changes neither, and the release gates only run at release time —
# so the images behind `latest` are rescanned every hour with the SAME policy
# as the gates:
#   resolver  CRITICAL,HIGH with a fix available, whole image
#             (release.yml, "Trivy vulnerability scan (gate)")
#   updater   HIGH with a fix available everywhere except the vendored cosign
#             binary; CRITICAL with a fix available everywhere, cosign included
#             (updater.yml, the two "Trivy: … (gate)" steps)
#
# Whether a rebuild would fix what the gate refuses is not deduced, it is
# TRIED: the workflow builds a candidate image from the current pins and
# scans it, and this script compares.
#   * It used to be deduced from where Trivy located the package (base layer
#     → "needs a new base digest"). Trivy attributes a package to the oldest
#     layer carrying that name and version, so a library the build stage
#     copies over the base's was read as out of reach: CVE-2026-124851
#     (libzstd1, fixed in trixie-security) stayed unrebuilt on 2026-11-25.
#   * A deduction also cannot tell a fix that is announced from one that is
#     installable from the mirrors the build uses. A candidate can.
# A release is asked for only when the candidate is CLEAN under the gate:
# anything less would be refused by the release's own gate, after its
# immutable tag was pushed. A candidate that is not clean costs nothing and
# is simply built again an hour later — nothing is ever given up on.
#
# Two passes per run:
#   1. without CANDIDATE: `clean`, `pending`, or `probe` (build a candidate);
#   2. with CANDIDATE (or CANDIDATE_FAILED=1): `new` or `waiting`.
#
# Inputs (environment):
#   POLICY            resolver | updater
#   DIGEST            index digest of the published image that was scanned
#   STATE_KEY         prefix of the attempt record in .build-state.json
#                     (rescan_resolver | rescan_updater)
#   EXPECT_ARCHS      architectures the published reports must all cover
#                     (default "amd64 arm64": the release gate scans both)
#   CANDIDATE         Trivy JSON reports of the candidate image, one per
#                     platform, space-separated (pass 2). They must cover
#                     EXPECT_ARCHS exactly, like the published ones: a fix
#                     that is installable on one architecture only would
#                     otherwise read as a clean candidate, and the release
#                     would then fail at its own scan of the other one —
#                     after its immutable tag was pushed.
#   CANDIDATE_FAILED  1 when a candidate build or its scan failed (pass 2)
#   NOW               epoch seconds (default: the current time)
#   PENDING_HOURS     how long a triggered rebuild may take to be published
#                     before another may be tried (default 6; a release takes
#                     ~1 h)
#   MAX_BACKOFF_HOURS upper bound of the wait between attempts (default 48)
# Arguments: one Trivy JSON report per platform of the PUBLISHED image.
# Files: .build-state.json in the current directory (attempt record).
#
# Output (stdout, KEY=VALUE lines for $GITHUB_OUTPUT, values sanitised to
# one line of printable characters):
#   status=clean    nothing the gate would refuse
#   status=probe    findings, no attempt in flight: build a candidate and
#                   call again with CANDIDATE (pass 1 only)
#   status=new      the candidate is clean: publish a rebuild
#   status=waiting  the candidate still carries findings (or could not be
#                   built this hour): nothing to publish, tried again next run
#   status=pending  an attempt was made recently (for this digest or for
#                   exactly these findings): wait for it before another
#   vulns=<16 hex>  fingerprint of the published findings (empty if none)
#   tries=<n>       with `new`: the number of this attempt; otherwise the
#                   recorded number (0 if none)
#   alert=none | unfixed | retrying | clear
#                   unfixed:  a rebuild does not fix the findings yet
#                   retrying: an earlier attempt did not resolve them (lost or
#                             failed release, or a rebuild that still had them)
#                   clear:    clean — close what was opened
#   count=<n>       number of distinct published findings
#   summary=<text>  the published findings, "ID (package)", truncated
#   remaining=<text> the findings the candidate still carries on any
#                   platform (waiting)
#   reason=<text>   one sentence for the issue body or the log
#
# Attempt record (<STATE_KEY>_digest/_vulns/_at/_tries, written by
# write-state.sh only when the monitor publishes the rebuild this script asked
# for). It bounds the attempts instead of forbidding them: while the published
# digest is the one the last attempt started from, or the findings are exactly
# the ones it was made for, the next attempt waits PENDING_HOURS, then twice
# that, … up to MAX_BACKOFF_HOURS. A release that keeps failing therefore
# costs one revision tag every two days at worst, and the first one that
# works ends it.
# A malformed report or state file is an error (exit 1): a scanner outage
# must fail the run visibly, never read as "clean" or as "rebuild".
set -euo pipefail

: "${POLICY:?}" "${DIGEST:?}" "${STATE_KEY:?}"
export EXPECT_ARCHS="${EXPECT_ARCHS:-amd64 arm64}"
export PENDING_HOURS="${PENDING_HOURS:-6}"
export MAX_BACKOFF_HOURS="${MAX_BACKOFF_HOURS:-48}"
NOW="${NOW:-$(date +%s)}"; export NOW
export CANDIDATE="${CANDIDATE:-}" CANDIDATE_FAILED="${CANDIDATE_FAILED:-}"
case "$POLICY" in resolver|updater) ;; *) echo "::error::unknown POLICY '$POLICY'" >&2; exit 1 ;; esac
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::DIGEST '$DIGEST' is not a sha256 digest" >&2; exit 1; }
[[ "$NOW" =~ ^[0-9]+$ && "$PENDING_HOURS" =~ ^[1-9][0-9]*$ && "$MAX_BACKOFF_HOURS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "::error::NOW, PENDING_HOURS and MAX_BACKOFF_HOURS must be integers" >&2; exit 1; }
case "$CANDIDATE_FAILED" in ""|0|1) ;; *) echo "::error::CANDIDATE_FAILED must be empty, 0 or 1" >&2; exit 1 ;; esac
[ $# -ge 1 ] || { echo "::error::usage: rescan-decide.sh <trivy-report.json>..." >&2; exit 1; }

python3 - "$@" <<'PY'
import hashlib, json, os, re, sys

policy, digest, key = os.environ["POLICY"], os.environ["DIGEST"], os.environ["STATE_KEY"]
expect = set(os.environ["EXPECT_ARCHS"].split())
now = int(os.environ["NOW"])
pending_hours, max_backoff = int(os.environ["PENDING_HOURS"]), int(os.environ["MAX_BACKOFF_HOURS"])
candidate, candidate_failed = os.environ["CANDIDATE"], os.environ["CANDIDATE_FAILED"] == "1"

def fail(msg):
    print(f"::error::rescan: {msg}", file=sys.stderr)
    sys.exit(1)

def load(path):
    try:
        with open(path) as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"{path}: unreadable Trivy report ({e})")
    if not isinstance(report, dict) or report.get("SchemaVersion") != 2:
        fail(f"{path}: not a Trivy JSON report (SchemaVersion 2)")
    return report

def refused(report, path):
    """What the release gate of this image refuses, as "ID (package)"."""
    found = set()
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
            found.add(f"{vid} ({pkg})")
    return found

published, archs = set(), set()
for path in sys.argv[1:]:
    report = load(path)
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
    published |= refused(report, path)

if archs != expect:
    fail(f"reports cover {sorted(archs)}, expected {sorted(expect)}")

try:
    with open(".build-state.json") as f:
        state = json.load(f)
    if not isinstance(state, dict):
        raise ValueError("not a JSON object")
except (OSError, ValueError) as e:
    fail(f".build-state.json unreadable ({e})")

def number(name, default):
    try:
        n = int(state.get(f"{key}_{name}", default))
    except (TypeError, ValueError):
        return default
    return n if n >= 0 else default

items = sorted(published)
fp = hashlib.sha256("\n".join(items).encode()).hexdigest()[:16] if items else ""
rec_digest, rec_vulns = state.get(f"{key}_digest"), state.get(f"{key}_vulns")
rec_at = number("at", 0)
# A record from before attempts were counted is one attempt.
rec_tries = max(number("tries", 1), 1) if (rec_digest or rec_vulns) else 0
age_h = (now - rec_at) // 3600 if rec_at and rec_at <= now else None
# The last attempt is about this situation when it started from this very
# digest (its rebuild is not out) or was made for exactly these findings (its
# rebuild is out and still has them).
same = bool(items) and (rec_digest == digest or rec_vulns == fp)
wait_h = min(pending_hours * 2 ** (rec_tries - 1), max_backoff) if same else 0

status, alert, reason, remaining, tries = "clean", "clear", "", [], rec_tries if same else 0
if not items:
    tries = 0
elif same and age_h is not None and age_h < wait_h:
    status = "pending"
    if rec_digest == digest and age_h < pending_hours:
        alert = "none"
        reason = f"A rebuild was triggered from this digest {age_h} h ago and is not published yet."
    else:
        alert = "retrying"
        what = ("its release has not been published" if rec_digest == digest
                else "the rebuild it published still carries exactly these findings")
        reason = (f"Attempt {rec_tries} was made {age_h} h ago and {what} "
                  "(see the release workflow's runs and issues). "
                  f"The next attempt is made {wait_h} h after it, if a candidate build is clean by then.")
elif candidate_failed:
    status, alert = "waiting", "none"
    reason = ("The candidate build or its scan failed in this run, so nothing is known about a rebuild. "
              "It is tried again on the next run.")
elif not candidate:
    status, alert = "probe", "none"
else:
    found, cand_archs = set(), set()
    for path in candidate.split():
        report = load(path)
        arch = ((report.get("Metadata") or {}).get("ImageConfig") or {}).get("architecture")
        if not arch:
            fail(f"{path}: no architecture in the candidate report")
        cand_archs.add(arch)
        found |= refused(report, path)
    if cand_archs != expect:
        fail(f"candidate reports cover {sorted(cand_archs)}, expected {sorted(expect)}")
    remaining = sorted(found)
    if remaining:
        status, alert = "waiting", "unfixed"
        reason = ("A rebuild does not fix this yet: an image built in this run from the current pins "
                  "still carries the findings listed as remaining, on at least one platform. The fix is not installable yet, or it "
                  "needs a newer base image or a newer pinned component. A candidate is built again every "
                  "hour and a new revision is published by itself as soon as one is clean.")
    else:
        status = "new"
        tries = rec_tries + 1 if same else 1
        alert = "retrying" if tries > 1 else "none"
        if tries > 1:
            reason = (f"Attempt {tries}: the previous one did not resolve these findings, and a candidate "
                      "built in this run is clean. A new revision is being published.")

def clean(text, limit=900):
    # One line of printable text: these values go to $GITHUB_OUTPUT.
    text = re.sub(r"[^\w .,:;()+/@~\[\]'-]", "?", text)
    return text if len(text) <= limit else text[:limit] + " ..."

print(f"status={status}")
print(f"vulns={fp}")
print(f"tries={tries}")
print(f"alert={alert}")
print(f"count={len(items)}")
print(f"summary={clean(', '.join(items))}")
print(f"remaining={clean(', '.join(remaining))}")
print(f"reason={clean(reason)}")
PY
