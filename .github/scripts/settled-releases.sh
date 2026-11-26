#!/usr/bin/env bash
# Which upstream releases the monitor may adopt unattended: published, stable,
# and out for long enough. Used by upstream-check.yml for the sidecar's
# vendored cosign, ahead of pick-version.sh.
#
# Why wait: the binary of a followed release ends up in the sidecar, which
# runs as root with the Docker socket on every host. A release that was
# published by mistake or through a compromised upstream account is usually
# withdrawn within hours or days; adopting a release in its first hour means
# shipping that one too. The wait is the time upstream and everyone else have
# to notice. (The image's signature is checked as well, in the workflow: that
# proves who published it, not that it should have been.)
#
# Usage:  settled-releases.sh < releases.json
#         stdin: the JSON array of GET /repos/<owner>/<repo>/releases
# Environment:
#   MIN_AGE_HOURS  a release counts once it has been out this long (default
#                  72; 0 takes every stable release)
#   NOW            epoch seconds (default: the current time)
# Output: one tag name per line — neither a draft nor a pre-release, with a
#         publication date at least MIN_AGE_HOURS old. A release without a
#         usable date is left out: unknown age is not "old enough".
# Exit status: 1 when stdin is not a JSON array of releases or the settings
#              are not integers — a listing that cannot be read must keep the
#              current pin (the caller's fallback), never pass as "nothing new".
set -euo pipefail

export MIN_AGE_HOURS="${MIN_AGE_HOURS:-72}"
NOW="${NOW:-$(date +%s)}"; export NOW
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ && "$NOW" =~ ^[0-9]+$ ]] \
  || { echo "::error::settled-releases.sh: MIN_AGE_HOURS and NOW must be integers" >&2; exit 1; }

# The program is passed with -c so that stdin stays the release listing.
python3 -c '
import datetime, json, os, sys

try:
    releases = json.load(sys.stdin)
    if not isinstance(releases, list):
        raise ValueError("not a JSON array")
except ValueError as e:
    print(f"::error::settled-releases.sh: unreadable release listing ({e})", file=sys.stderr)
    sys.exit(1)

limit = int(os.environ["NOW"]) - int(os.environ["MIN_AGE_HOURS"]) * 3600
for r in releases:
    if not isinstance(r, dict) or r.get("draft") or r.get("prerelease"):
        continue
    tag, published = r.get("tag_name"), r.get("published_at")
    if not isinstance(tag, str) or not isinstance(published, str) or "\n" in tag:
        continue
    try:
        at = datetime.datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        continue
    if at.timestamp() <= limit:
        print(tag)
'
