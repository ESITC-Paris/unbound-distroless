#!/usr/bin/env bash
# Is the release of the CURRENT revision (the one versions.env holds) really
# out? Pure decision for upstream-check.yml, so tests/monitor.sh can exercise
# it; the workflow gathers the facts.
#
# Catches a release that was lost whatever the cause: a run cancelled while
# pending, a dispatch that never arrived, a timeout, a registry blip at the
# very end. Older revisions are not checked: once a newer one is published
# they are superseded, and re-running them would move `latest` backwards.
#
# Inputs (environment):
#   TAG_IN_GIT      yes | no — the release tag exists in the repository
#   COMPLETE        yes | no — immutable tag on both registries, latest on both
#                   at that digest, GitHub Release present
#   RUNS            the release workflow's runs for this tag, one per line,
#                   "<status> <conclusion>", newest first (may be empty)
#   MAX_ATTEMPTS    re-dispatch at most this many runs in total (default 3)
# Output (stdout): health=<value> and reason=<text>
#   complete    nothing to do
#   untagged    versions.env names a revision nobody tagged: nothing to release
#   in-flight   a run is queued or running: wait
#   redispatch  incomplete, nothing running, attempts left: dispatch the
#               release again (a published-and-signed tag is resumed, see
#               release-mode.sh; an absent one is built)
#   give-up     incomplete after MAX_ATTEMPTS runs: open an issue
set -euo pipefail

: "${MAX_ATTEMPTS:=3}"
for v in TAG_IN_GIT COMPLETE; do
  case "${!v:-}" in yes|no) ;; *) echo "::error::$v must be yes or no, got '${!v:-}'" >&2; exit 1 ;; esac
done
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || { echo "::error::MAX_ATTEMPTS must be an integer" >&2; exit 1; }

out() { printf 'health=%s\nreason=%s\n' "$1" "$2"; exit 0; }

[ "$TAG_IN_GIT" = yes ] || out untagged "no release tag for the revision in versions.env"
[ "$COMPLETE" = no ] || out complete "published"

attempts=0; active=0; last=""
while read -r status conclusion; do
  [ -n "${status:-}" ] || continue
  attempts=$((attempts + 1))
  [ -n "$last" ] || last="$status${conclusion:+/$conclusion}"
  case "$status" in
    queued|in_progress|waiting|pending|requested) active=1 ;;
    completed) ;;
    *) echo "::error::unknown run status '$status'" >&2; exit 1 ;;
  esac
done <<<"${RUNS:-}"

[ "$active" = 0 ] || out in-flight "a release run is queued or running"
if [ "$attempts" -lt "$MAX_ATTEMPTS" ]; then
  out redispatch "incomplete after $attempts run(s) (last: ${last:-none})"
fi
out give-up "still incomplete after $attempts runs (last: $last)"
