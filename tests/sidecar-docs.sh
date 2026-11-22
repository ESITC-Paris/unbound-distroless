#!/usr/bin/env bash
# The sidecar's documentation against the code and against Compose:
#
#   1. updater/README.md's install recipe (the fenced block after
#      `<!-- sidecar:install`) is run as written in a scratch project holding
#      a copy of the root docker-compose.yml. Only the `curl` of
#      updater/compose.snippet.yml is replaced by a copy of this checkout's
#      file (the URL is checked to be that file on main); the following
#      `docker compose` lines are not run (they would bind port 53). The
#      merged project is then checked with `docker compose config`.
#   1b. The complete file the root README prints for "Resolver with automatic
#      updates" (the block after `<!-- quickstart:compose-sidecar`) is the
#      same project as docker-compose.yml merged with
#      updater/compose.snippet.yml, once `docker compose config` has parsed
#      both in /opt/unbound.
#   2. docs/production/docker-compose.yml: `docker compose config` refuses it
#      without HC_URL and accepts it with one, and the result is checked.
#   3. Both projects are checked for what the sidecar requires at run time:
#      the project directory mounted at the same absolute path, read-only;
#      the Docker socket; a named volume on the resolver's /var/lib/unbound;
#      exactly one service the sidecar's discovery would pick as the
#      resolver; the loop and the metrics services on the same image (self-
#      update moves both); /metrics published on 127.0.0.1 only.
#   4. Every environment variable in the "Variables" table of
#      updater/README.md is read by the sidecar's code, every variable the
#      code reads from its environment is in the table, and each default in
#      the table is the code's default.
#   5. No hand-written X.Y.Z-rN release number in the files that document the
#      sidecar and the reference deployment: it would be stale at the next
#      automated revision.
#
# Usage: tests/sidecar-docs.sh   (bash, docker compose — no daemon needed —,
# jq, grep, sed, awk)
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/.." && pwd)
README="$ROOT/updater/README.md"
SNIPPET_URL=https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/updater/compose.snippet.yml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }

command -v jq >/dev/null || { echo "FAIL: jq not found" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "FAIL: docker compose not found" >&2; exit 1; }

# block <marker>: the fenced block after `<!-- <marker>` in updater/README.md,
# backslash continuations joined.
block() {
  awk -v m="<!-- $1" '
    index($0, m) == 1 { found = 1; next }
    found && !inside && /^```/ { inside = 1; next }
    inside && /^```/ { exit }
    inside { print }
  ' "$README" | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta'
}

# check_project <label> <dir> <config-json> — section 3.
check_project() {
  local label="$1" dir="$2" cfg="$3" sidecar_img self_repo n
  sidecar_img=$(jq -r '.services["unbound-autoupdate"].image // empty' <<<"$cfg")
  [ -n "$sidecar_img" ] || { fail "$label: no unbound-autoupdate service"; return; }
  [ "$(jq -r '.services["unbound-metrics"].image // empty' <<<"$cfg")" = "$sidecar_img" ] \
    || fail "$label: unbound-metrics does not declare the sidecar's image"
  [ "$(jq -r '.services["unbound-metrics"].command | join(" ")' <<<"$cfg")" = metrics ] \
    || fail "$label: unbound-metrics does not run the metrics mode"

  jq -e --arg d "$dir" '.services["unbound-autoupdate"].volumes[]
      | select(.type == "bind" and .source == $d and .target == $d and .read_only == true)' \
      <<<"$cfg" >/dev/null \
    || fail "$label: the project directory $dir is not mounted read-only at the same path in the sidecar"
  local s
  for s in unbound-autoupdate unbound-metrics; do
    jq -e --arg s "$s" '.services[$s].volumes[]
        | select(.type == "bind" and .source == "/var/run/docker.sock" and .target == "/var/run/docker.sock")' \
        <<<"$cfg" >/dev/null || fail "$label: $s does not mount the Docker socket"
    jq -e --arg s "$s" '.services[$s].volumes[]
        | select(.type == "volume" and .source == "autoupdate-state" and .target == "/var/lib/unbound-autoupdate")' \
        <<<"$cfg" >/dev/null || fail "$label: $s does not mount the autoupdate-state volume"
  done
  jq -e '.services["unbound-metrics"].volumes[]
      | select(.source == "autoupdate-state" and .read_only == true)' <<<"$cfg" >/dev/null \
    || fail "$label: unbound-metrics mounts the state volume writable"
  jq -e '[.services["unbound-metrics"].ports[] | select(.host_ip != "127.0.0.1")] | length == 0' \
      <<<"$cfg" >/dev/null || fail "$label: /metrics is published beyond 127.0.0.1"

  # Discovery (updater/lib/discover.sh): a sibling whose image reference
  # contains "unbound", on another repository than the sidecar's own.
  self_repo=$(jq -rn --arg r "$sidecar_img" '$r | sub("@.*$"; "") | sub(":[^:/]*$"; "")')
  n=$(jq --arg repo "$self_repo" '[.services | to_entries[]
        | select(.value.image | test("unbound"))
        | select((.value.image | sub("@.*$"; "") | sub(":[^:/]*$"; "")) != $repo)] | length' <<<"$cfg")
  [ "$n" = 1 ] || fail "$label: the sidecar's discovery would find $n resolver candidates, not 1"
  jq -e '.services.unbound.volumes[] | select(.type == "volume" and .target == "/var/lib/unbound")' \
      <<<"$cfg" >/dev/null || fail "$label: the resolver has no named volume on /var/lib/unbound"
}

# ── 1. The install recipe, on the root docker-compose.yml ──────────────────────
proj="$WORK/project dir"     # a space: the recipe must quote the path
mkdir -p "$proj"
cp "$ROOT/docker-compose.yml" "$proj/"
recipe=$(block sidecar:install)
[ -n "$recipe" ] || { echo "FAIL: no <!-- sidecar:install block in updater/README.md" >&2; exit 1; }
first=$(head -1 <<<"$recipe")
case "$first" in
  "curl -fsSL $SNIPPET_URL | "*"> docker-compose.override.yml") : ;;
  *) fail "install recipe: the first command is not the curl of $SNIPPET_URL into docker-compose.override.yml: $first" ;;
esac
while IFS= read -r line; do
  case "$line" in "docker compose "*) : ;; *) fail "install recipe: unexpected line: $line" ;; esac
done < <(tail -n +2 <<<"$recipe")
local_cmd="cat \"$ROOT/updater/compose.snippet.yml\"${first#"curl -fsSL $SNIPPET_URL"}"
( cd "$proj" && bash -euo pipefail -c "$local_cmd" ) || fail "install recipe: the curl line failed"
real_proj=$(cd "$proj" && pwd -P)
if cfg=$(cd "$proj" && docker compose config --format json 2>"$WORK/err"); then
  # Compose reports the directory as it resolved it; compare like with like.
  jq -e '.services | has("unbound") and has("unbound-autoupdate") and has("unbound-metrics")' <<<"$cfg" >/dev/null \
    || fail "install recipe: docker-compose.override.yml was not merged with docker-compose.yml"
  dir=$(jq -r '.services["unbound-autoupdate"].volumes[] | select(.target != "/var/run/docker.sock" and .type == "bind") | .target' <<<"$cfg")
  case "$dir" in "$proj"|"$real_proj") : ;; *) fail "install recipe: the project directory was replaced by '$dir'" ;; esac
  check_project "root docker-compose.yml + compose.snippet.yml" "$dir" "$cfg"
  pass "updater/README.md install recipe: docker-compose.yml + docker-compose.override.yml validate and meet the sidecar's requirements"
else
  fail "install recipe: docker compose config failed: $(cat "$WORK/err")"
fi

# ── 1b. The root README's complete file ───────────────────────────────────────
mkdir -p "$WORK/readme"
awk -v m="<!-- quickstart:compose-sidecar" '
  index($0, m) == 1 { found = 1; next }
  found && !inside && /^```/ { inside = 1; next }
  inside && /^```/ { exit }
  inside { print }
' "$ROOT/README.md" > "$WORK/readme/docker-compose.yml"
if [ ! -s "$WORK/readme/docker-compose.yml" ]; then
  fail "README.md: no <!-- quickstart:compose-sidecar block"
elif ! got=$(docker compose -f "$WORK/readme/docker-compose.yml" --project-directory /opt/unbound config --format json 2>"$WORK/err"); then
  fail "README.md sidecar file: docker compose config failed: $(cat "$WORK/err")"
elif ! want=$(docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/updater/compose.snippet.yml" --project-directory /opt/unbound config --format json 2>"$WORK/err"); then
  fail "docker-compose.yml + compose.snippet.yml: docker compose config failed: $(cat "$WORK/err")"
elif ! diff <(jq -S . <<<"$got") <(jq -S . <<<"$want") >&2; then
  fail "README.md sidecar file differs from docker-compose.yml + updater/compose.snippet.yml"
else
  check_project "README.md sidecar file" /opt/unbound "$got"
  pass "README.md sidecar file: same project as docker-compose.yml + updater/compose.snippet.yml"
fi

# ── 2. The reference production project ───────────────────────────────────────
prod="$ROOT/docs/production/docker-compose.yml"
if err=$(env -u HC_URL docker compose -f "$prod" --project-directory /opt/unbound config --quiet 2>&1); then
  fail "production: docker compose config accepted the file without HC_URL"
else
  grep -q 'set HC_URL in .env' <<<"$err" || fail "production: missing HC_URL fails with an unexpected message: $err"
fi
if cfg=$(HC_URL=https://hc.example/ping docker compose -f "$prod" --project-directory /opt/unbound config --format json 2>"$WORK/err"); then
  check_project "docs/production/docker-compose.yml" /opt/unbound "$cfg"
  [ "$(jq -r .name <<<"$cfg")" = unbound ] || fail "production: the project is not named unbound (volume names in docs/production.md)"
  jq -e '.services.unbound | .read_only == true and (.cap_drop == ["ALL"]) and (.cap_add == ["NET_BIND_SERVICE"])
         and (.security_opt == ["no-new-privileges:true"])' <<<"$cfg" >/dev/null \
    || fail "production: the resolver's hardening differs from docs/production.md"
  jq -e '.services.unbound.volumes[] | select(.type == "bind" and .source == "/opt/unbound/unbound.conf")' \
      <<<"$cfg" >/dev/null || fail "production: unbound.conf is not mounted from the project directory"
  pass "docs/production/docker-compose.yml: refused without HC_URL, valid with it, meets the sidecar's requirements"
else
  fail "production: docker compose config failed: $(cat "$WORK/err")"
fi

# ── 4. Variables table versus code ────────────────────────────────────────────
code_files=("$ROOT/updater/unbound-autoupdate" "$ROOT/updater/entrypoint.sh" "$ROOT"/updater/lib/*.sh "$ROOT/updater/www/cgi-bin/metrics")
# Names the code reads with a default or an emptiness test but that are set by
# the code itself, never by the operator.
INTERNAL="CACHE_NOTE COMPOSE_EXTRA_FILE COMPOSE_PROJECT DECLARED_IMAGE_REF DISCOVER_ALL PRE_TAG_ID PRUNE_PROTECT_IDS RECOVERING ROLLBACK_FILE SELF_IMAGE_ID SELF_ROLLBACK_FILE SWAPPED_CONTAINER VERIFY_FAILURE"
# "NAME<TAB>default" for every ${NAME:-default} / ${NAME:=default} in the code.
code_defaults=$(grep -ohE '\$\{[A-Z_][A-Z0-9_]*:[-=][^}]*\}' "${code_files[@]}" \
  | sed -E 's/^\$\{([A-Z0-9_]+):[-=](.*)\}$/\1\t\2/' | sort -u)
code_vars=$(cut -f1 <<<"$code_defaults" | sort -u | grep -vxF -f <(tr ' ' '\n' <<<"$INTERNAL"))

table=$(awk '
  /^## / { insec = ($0 == "## Variables"); next }
  insec && /^\| `[A-Z_][A-Z0-9_]*` \|/ { print }' "$README")
[ -n "$table" ] || fail "updater/README.md: no Variables table found"
doc_vars=$(sed -E 's/^\| `([A-Z0-9_]+)` \|.*/\1/' <<<"$table" | sort -u)

while IFS= read -r v; do
  [ -n "$v" ] || continue
  grep -qxF "$v" <<<"$doc_vars" || fail "variable $v is read by the code but not in updater/README.md's table"
done <<<"$code_vars"
while IFS= read -r v; do
  [ -n "$v" ] || continue
  grep -qxF "$v" <<<"$code_vars" || fail "variable $v is in updater/README.md's table but not read by the code"
done <<<"$doc_vars"

# Default column: a single `literal` must be one of the code's defaults for
# that name; prose (unset, auto, …) means the code's default is empty or
# computed from another variable (contains `${`).
while IFS= read -r row; do
  v=$(sed -E 's/^\| `([A-Z0-9_]+)` \|.*/\1/' <<<"$row")
  cell=$(awk -F' \\| ' '{ print $2 }' <<<"$row")
  defaults=$(awk -F'\t' -v v="$v" '$1 == v { print $2 }' <<<"$code_defaults")
  if [[ "$cell" =~ ^\`([^\`]*)\`$ ]]; then
    grep -qxF -- "${BASH_REMATCH[1]}" <<<"$defaults" \
      || fail "variable $v: documented default '${BASH_REMATCH[1]}' is not the code's ($(tr '\n' ' ' <<<"$defaults"))"
  else
    [ -z "$(grep -v -e '^$' -e '\${' <<<"$defaults" || true)" ] \
      || fail "variable $v: documented default '$cell' but the code defaults to '$(tr '\n' ' ' <<<"$defaults")'"
  fi
done <<<"$table"
[ "$FAILED" = 0 ] && pass "updater/README.md variables: $(wc -l <<<"$doc_vars" | tr -d ' ') documented, same set and defaults as the code"

# ── 5. No hand-written release number ────────────────────────────────────────
if hits=$(grep -nE '[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+' "$README" "$ROOT/updater/compose.snippet.yml" \
            "$ROOT/docs/production.md" "$ROOT/docs/production/docker-compose.yml" \
            "$ROOT"/docs/observability/*); then
  fail "hand-written X.Y.Z-rN release numbers: $hits"
else
  pass "no hand-written X.Y.Z-rN in the sidecar and production documentation"
fi

[ "$FAILED" = 0 ] || { echo "sidecar-docs: FAILED" >&2; exit 1; }
echo "sidecar-docs: all checks passed"
