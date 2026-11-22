#!/usr/bin/env bash
# Applies this repository's GitHub configuration (production-trust design,
# workstream 1) from the files next to this script. Idempotent: every call
# sets a desired state, so re-running it converges again after a drift.
#
# Usage:
#   .github/settings/apply.sh [--dry-run] [--bot-bypass deploy-key|app:<app-id>|none]
#
#   --dry-run     print every call instead of making it. GET requests still
#                 run (read-only) so the plan shows create-vs-update exactly.
#   --bot-bypass  the credential upstream-check.yml pushes with, made the only
#                 bypass actor of the `main` and release-tag-creation rulesets:
#                   deploy-key  every deploy key of the repository (the API
#                               cannot name one key: actor_id must be null)
#                   app:<id>    a GitHub App (fallback if deploy keys cannot
#                               be bypass actors on this plan)
#                   none        (default) those two rulesets are NOT applied —
#                               they would block the bot's hourly push
#
# Order (each step keeps the hourly automation working):
#   1. Push the workflow changes (environments are created on first use).
#   2. Create the deploy key and its secret, by hand — this script never
#      handles key material:
#        ssh-keygen -t ed25519 -N '' -C upstream-check -f monitor_key
#        gh repo deploy-key add monitor_key.pub --allow-write --title upstream-check
#        gh secret set MONITOR_DEPLOY_KEY --env monitor < monitor_key
#        shred -u monitor_key monitor_key.pub   # or rm -P on macOS
#   3. Move the Docker Hub secrets into the `release` environment, then
#      delete the repository-level copies (old release.yml revisions, which
#      lack the published-tag guard, then cannot log in to Docker Hub):
#        gh secret set DOCKERHUB_USERNAME --env release
#        gh secret set DOCKERHUB_TOKEN --env release
#        gh secret delete DOCKERHUB_USERNAME; gh secret delete DOCKERHUB_TOKEN
#   4. Run this script with --dry-run, read the plan, run it with
#      --bot-bypass deploy-key.
#   5. Check: a force-push to main, a v* tag push by a non-bypass actor and
#      moving an existing tag are all rejected; the next automated release
#      completes unattended.
#
# Requires gh (authenticated as a repository admin) and python3.
set -euo pipefail

REPO=${REPO:-ESITC-Paris/unbound-distroless}
# Repository role id of "admin" as used in ruleset bypass lists (the id the
# GitHub UI exports for the admin role; not listed in the REST docs).
ADMIN_ROLE_ID=${ADMIN_ROLE_ID:-5}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
BOT=none

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --bot-bypass) BOT=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$BOT" in
  none|deploy-key) ;;
  app:[0-9]*) [[ "$BOT" =~ ^app:[0-9]+$ ]] || { echo "bad --bot-bypass $BOT" >&2; exit 2; } ;;
  *) echo "bad --bot-bypass '$BOT' (deploy-key, app:<id> or none)" >&2; exit 2 ;;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# The plan goes to fd 3 (the original stdout): call sites discard the API's
# response bodies with >/dev/null, and that must never swallow the plan.
exec 3>&1
plan() { printf '%s\n' "$*" >&3; }
WOULD=""; [ "$DRY_RUN" = 0 ] || WOULD="would be "

# api <METHOD> <path> [json-body]: a change. Printed, and made unless this is
# a dry run — a dry run never sends anything but GETs.
api() {
  local method=$1 path=$2 body=${3:-}
  [ "$method" != GET ] || { echo "api() is for changes; use get()" >&2; exit 1; }
  if [ "$DRY_RUN" = 1 ]; then plan "PLAN $method $path"; else plan "+ $method $path"; fi
  [ -z "$body" ] || plan "      body: $body"
  [ "$DRY_RUN" = 0 ] || return 0
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$TMP/body.json"
    gh api -X "$method" "$path" -H "X-GitHub-Api-Version: 2022-11-28" --input "$TMP/body.json"
  else
    gh api -X "$method" "$path" -H "X-GitHub-Api-Version: 2022-11-28"
  fi
}

# get <path>: read-only, also in a dry run. Prints the JSON body, or nothing
# when the resource does not exist (404); any other error stops the script.
get() {
  # gh prints the error body on stdout too: keep it out of the result.
  if gh api "$1" -H "X-GitHub-Api-Version: 2022-11-28" >"$TMP/get.out" 2>"$TMP/get.err"; then
    cat "$TMP/get.out"; return 0
  fi
  grep -q 'HTTP 404' "$TMP/get.err" && return 0
  cat "$TMP/get.err" >&2; exit 1
}

json() { python3 -c "import json,sys; print(json.dumps($1))" "${@:2}"; }

# --- Rulesets ----------------------------------------------------------------
# ruleset_body <file> <bot>: the ruleset JSON, with the admin role id filled
# in and, unless <bot> is none, the bot credential appended to its bypass
# actors.
ruleset_body() {
  python3 - "$1" "$2" "$ADMIN_ROLE_ID" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
bot, admin = sys.argv[2], int(sys.argv[3])
for a in r["bypass_actors"]:
    if a["actor_type"] == "RepositoryRole":
        a["actor_id"] = admin
if bot == "deploy-key":
    r["bypass_actors"].append({"actor_id": None, "actor_type": "DeployKey", "bypass_mode": "always"})
elif bot.startswith("app:"):
    r["bypass_actors"].append({"actor_id": int(bot[4:]), "actor_type": "Integration", "bypass_mode": "always"})
print(json.dumps(r))
PY
}

RULESETS=$(get "repos/$REPO/rulesets?includes_parents=false&per_page=100")
apply_ruleset() {  # apply_ruleset <file> <bot-bypass: yes|no>
  local file=$1 bot=$2 name body id
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$file")
  if [ "$bot" = yes ] && [ "$BOT" = none ]; then
    plan "SKIP ruleset '$name': it would block the monitor's push; rerun with --bot-bypass once the deploy key exists"
    return 0
  fi
  body=$(ruleset_body "$file" "$([ "$bot" = yes ] && echo "$BOT" || echo none)")
  # Repository-level rulesets only: an organisation ruleset of the same name
  # is not ours to rewrite.
  id=$(python3 -c 'import json,sys; n=sys.argv[1]; d=sys.stdin.read().strip(); print(next((str(r["id"]) for r in (json.loads(d) if d else []) if r["name"]==n), ""))' "$name" <<<"$RULESETS")
  if [ -n "$id" ]; then
    api PUT "repos/$REPO/rulesets/$id" "$body" >/dev/null
    plan "ruleset '$name': ${WOULD}updated (#$id)"
  else
    api POST "repos/$REPO/rulesets" "$body" >/dev/null
    plan "ruleset '$name': ${WOULD}created"
  fi
}

apply_ruleset "$DIR/ruleset-release-tags-immutable.json" no
apply_ruleset "$DIR/ruleset-release-tags-create.json" yes
apply_ruleset "$DIR/ruleset-main.json" yes

# --- Actions -----------------------------------------------------------------
# Read-only default token (every workflow declares its own permissions), and
# workflows may not approve pull requests.
api PUT "repos/$REPO/actions/permissions/workflow" \
  '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' >/dev/null
# Only GitHub-owned actions plus the ones in use — including those the
# composite actions call (trivy-action → setup-trivy) — and only by full SHA.
api PUT "repos/$REPO/actions/permissions" \
  '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}' >/dev/null
api PUT "repos/$REPO/actions/permissions/selected-actions" "$(json '{
  "github_owned_allowed": True,
  "verified_allowed": False,
  "patterns_allowed": [
    "aquasecurity/trivy-action@*", "aquasecurity/setup-trivy@*",
    "docker/setup-buildx-action@*", "docker/build-push-action@*", "docker/login-action@*",
    "sigstore/cosign-installer@*", "softprops/action-gh-release@*",
    "peter-evans/dockerhub-description@*", "ossf/scorecard-action@*"]}')" >/dev/null
plan "actions: read-only token, no PR approval, allow-list, SHA pinning required — ${WOULD}set"

# --- Security features -------------------------------------------------------
api PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null
api PUT "repos/$REPO/vulnerability-alerts" >/dev/null
api PUT "repos/$REPO/automated-security-fixes" >/dev/null
api PATCH "repos/$REPO" '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' >/dev/null
plan "security features — ${WOULD}enabled"

# --- Presentation ------------------------------------------------------------
api PATCH "repos/$REPO" "$(json '{"description": "Unbound DNS resolver on a distroless base: non-root, DNSSEC-validating, cosign-signed, SBOM and provenance, rebuilt automatically. Maintained by the IT department of ESITC Paris."}')" >/dev/null
api PUT "repos/$REPO/topics" '{"names":["unbound","dns","dns-resolver","dnssec","distroless","docker","container-image","cosign","sigstore","sbom","slsa","supply-chain-security"]}' >/dev/null
plan "description and topics — ${WOULD}set"

# --- Environments --------------------------------------------------------------
# apply_env <name> <type>:<pattern>...: custom ref policy, exactly these
# patterns. No reviewers or wait timer: either would make every release, and
# the hourly monitor, wait for a human.
#
# Order matters. Patterns are added before extras are deleted, so an
# environment that already has a custom policy never has zero patterns. The
# switch from "any ref" to a custom policy cannot avoid one such moment: the
# API accepts patterns only once custom_branch_policies is true. It is made
# only while no run that uses environments is queued or running, and the
# patterns follow immediately; a job starting in those seconds would be
# rejected, which the monitor's release-health check then re-dispatches.
busy_runs() {
  local wf n total=0
  for wf in release.yml updater.yml upstream-check.yml; do
    for st in queued in_progress waiting; do
      n=$(get "repos/$REPO/actions/workflows/$wf/runs?status=$st&per_page=1" \
        | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(json.loads(d)["total_count"] if d else 0)')
      total=$((total + n))
    done
  done
  echo "$total"
}
apply_env() {
  local name=$1; shift
  local envjson custom existing want id ref
  envjson=$(get "repos/$REPO/environments/$name")
  custom=$(python3 -c 'import json,sys; d=sys.stdin.read().strip(); e=json.loads(d) if d else {}; p=e.get("deployment_branch_policy") or {}; print("yes" if p.get("custom_branch_policies") else "no")' <<<"$envjson")
  if [ "$custom" = no ]; then
    if [ "$(busy_runs)" != 0 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        plan "WARNING environment '$name': a release or monitor run is queued or running — a real run would stop here"
      else
        echo "environment '$name': a release or monitor run is queued or running — retry when it is done" >&2
        exit 1
      fi
    fi
    api PUT "repos/$REPO/environments/$name" \
      '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' >/dev/null
    existing=""
  else
    existing=$(get "repos/$REPO/environments/$name/deployment-branch-policies?per_page=100" \
      | python3 -c 'import json,sys; d=sys.stdin.read().strip(); [print(p["id"], p.get("type","branch")+":"+p["name"]) for p in (json.loads(d).get("branch_policies") or [] if d else [])]')
  fi
  for want in "$@"; do
    if ! cut -s -d' ' -f2- <<<"$existing" | grep -qxF "$want"; then
      api POST "repos/$REPO/environments/$name/deployment-branch-policies" \
        "$(json '{"type": sys.argv[1], "name": sys.argv[2]}' "${want%%:*}" "${want#*:}")" >/dev/null
    fi
  done
  while read -r id ref; do
    [ -n "$id" ] || continue
    printf '%s\n' "$@" | grep -qxF "$ref" || api DELETE "repos/$REPO/environments/$name/deployment-branch-policies/$id" >/dev/null
  done <<<"$existing"
  plan "environment '$name' (${envjson:+exists}${envjson:-does not exist yet}, custom policy: $custom): ${WOULD}restricted to $*"
}
apply_env release 'tag:v*' 'tag:updater-v*'
apply_env monitor 'branch:main'

if [ "$DRY_RUN" = 1 ]; then plan "dry run: nothing was changed"; else plan "done"; fi
plan "Secrets are not managed here: see steps 2 and 3 at the top of this script."
