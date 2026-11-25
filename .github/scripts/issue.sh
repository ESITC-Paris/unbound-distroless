#!/usr/bin/env bash
# One open issue per title, assigned to the admin; closed when the condition
# it reports is over. Used by the published-image rescan (upstream-check.yml).
#
# Usage: issue.sh open  <title> <body>      open it unless one is already open
#        issue.sh close <title> <comment>   close every open issue with that title
# Environment: GH_TOKEN, GH_REPO (as for gh); ISSUE_ASSIGNEE (default euca01);
#              ISSUE_RETRY_SLEEP (seconds, multiplied by the attempt; default 20).
#
# Retried, and re-listed on every attempt: these calls are made when something
# is wrong, which is also when GitHub's own incidents happen. On 2026-11-25 a
# create answered with an error after having created the issue, unassigned —
# nobody was notified. So the issue is created WITHOUT its assignee, and
# assigned by a separate call that can be repeated; an attempt that fails
# half-way is picked up by the next one's listing instead of opening a second
# issue.
# Exit status: 0 done (or nothing to do), 1 after five failed attempts.
set -euo pipefail

[ $# -eq 3 ] || { echo "::error::usage: issue.sh open|close <title> <text>" >&2; exit 1; }
MODE=$1 TITLE=$2 TEXT=$3
case "$MODE" in open|close) ;; *) echo "::error::issue.sh: unknown mode '$MODE'" >&2; exit 1 ;; esac
[ -n "$TITLE" ] || { echo "::error::issue.sh: empty title" >&2; exit 1; }
ASSIGNEE=${ISSUE_ASSIGNEE:-euca01}
PAUSE=${ISSUE_RETRY_SLEEP:-20}

numbers() {
  gh issue list --state open --limit 200 --json number,title \
    | TITLE="$TITLE" python3 -c 'import json, os, sys
for i in json.load(sys.stdin):
    if i["title"] == os.environ["TITLE"]:
        print(i["number"])'
}

attempt() {
  local nums num
  nums=$(numbers) || return 1
  if [ "$MODE" = close ]; then
    for num in $nums; do
      gh issue close "$num" --comment "$TEXT" >/dev/null || return 1
      echo "closed #$num ($TITLE)"
    done
    return 0
  fi
  num=$(head -n 1 <<<"$nums")
  if [ -z "$num" ]; then
    num=$(gh issue create --title "$TITLE" --body "$TEXT" | grep -oE '[0-9]+$' | tail -n 1) || return 1
    [ -n "$num" ] || return 1
    echo "opened #$num ($TITLE)"
  else
    echo "already tracked in #$num ($TITLE)"
  fi
  gh issue edit "$num" --add-assignee "$ASSIGNEE" >/dev/null
}

for n in 1 2 3 4 5; do
  if attempt; then exit 0; fi
  echo "::warning::issue.sh $MODE '$TITLE': attempt $n failed" >&2
  [ "$n" = 5 ] || sleep $(( n * PAUSE ))
done
echo "::error::issue.sh: could not $MODE '$TITLE'" >&2
exit 1
