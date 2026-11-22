#!/usr/bin/env bash
# docs/observability/ against what the sidecar's metrics service emits.
#
#   1. `promtool check config` on prometheus.yml (which loads and checks
#      alerts.yml).
#   2. An exposition is produced the way the metrics service produces it:
#      `unbound-control stats_noreset` and the RFC 5011 trust-anchor file of a
#      real, running resolver, converted by the sidecar image's own
#      stats_to_prometheus and anchor_to_prometheus; then the sidecar's own
#      endpoint script (updater/www/cgi-bin/metrics) run in that image after a
#      recorded cycle, for the unbound_autoupdate_* and unbound_exporter_*
#      families. `promtool check metrics` must accept it.
#   3. Every unbound_* metric name in an alert expression exists in that
#      exposition, and every label matcher on it (`l="v"`, and each
#      alternative of `l=~"a|b"`) matches a sample.
#
# Usage: tests/observability.sh <sidecar-image> [<resolver-image>]
#   default resolver image: esitcparis/unbound-distroless:latest (pulled if
#   absent). Needs docker.
set -euo pipefail
export LC_ALL=C

SIDECAR="${1:?usage: tests/observability.sh <sidecar-image> [<resolver-image>]}"
RESOLVER="${2:-esitcparis/unbound-distroless:latest}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OBS="$ROOT/docs/observability"
PROMTOOL_IMAGE=prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996
NAME="obs-test-$$-$RANDOM"
WORK=$(mktemp -d)

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

docker image inspect "$SIDECAR" >/dev/null 2>&1 || fail "image $SIDECAR not found — build it first"

# ── 1 ──
docker run --rm -v "$OBS:/obs:ro" --entrypoint promtool "$PROMTOOL_IMAGE" \
  check config /obs/prometheus.yml >"$WORK/promtool" 2>&1 \
  || fail "promtool check config: $(cat "$WORK/promtool")"
pass "promtool check config docs/observability/prometheus.yml (and alerts.yml)"

# ── 2 ──
docker image inspect "$RESOLVER" >/dev/null 2>&1 || docker pull -q "$RESOLVER" >/dev/null
docker run -d --name "$NAME" "$RESOLVER" >/dev/null
for _ in $(seq 1 30); do
  docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf status >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$NAME" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset \
  > "$WORK/stats" || fail "unbound-control stats_noreset failed in $RESOLVER"
docker cp "$NAME:/var/lib/unbound/root.key" - | tar -xO > "$WORK/root.key" \
  || fail "cannot copy root.key out of $RESOLVER"
grep -q '^total.num.queries=' "$WORK/stats" || fail "no statistics from $RESOLVER: $(head -5 "$WORK/stats")"

docker run --rm -i -v "$WORK:/in:ro" --entrypoint /bin/bash "$SIDECAR" -c '
  set -euo pipefail
  LIB=/usr/local/lib/unbound-autoupdate
  export STATE_DIR=/tmp/state
  . "$LIB/log.sh"; . "$LIB/state.sh"; . "$LIB/metrics.sh"
  state_init
  stats_to_prometheus < /in/stats
  anchor_to_prometheus < /in/root.key
  record_cycle up_to_date 1 >/dev/null 2>&1
  # The endpoint script: no Docker socket here, so its own collection fails
  # and it serves the cycle metrics and unbound_exporter_* only.
  /usr/local/lib/unbound-autoupdate/www/cgi-bin/metrics | tr -d "\r" | sed "1,/^\$/d"
' > "$WORK/exposition" || fail "the sidecar image could not produce an exposition"

docker run --rm -i --entrypoint promtool "$PROMTOOL_IMAGE" check metrics < "$WORK/exposition" \
  >"$WORK/promtool" 2>&1 || fail "promtool check metrics: $(cat "$WORK/promtool")"
pass "exposition from $RESOLVER statistics through $SIDECAR: $(grep -vc '^#' "$WORK/exposition") samples, promtool-clean"

# ── 3 ──
# Expressions only (the expr: values), joined onto one line per rule.
awk '
  /^[[:space:]]*expr:/ { if (e != "") print e; e = $0; sub(/^[[:space:]]*expr:[[:space:]]*\|?/, "", e); inexpr = 1; next }
  inexpr && /^[[:space:]]*(for|labels|annotations|- alert):?/ { print e; e = ""; inexpr = 0; next }
  inexpr { e = e " " $0 }
  END { if (e != "") print e }' "$OBS/alerts.yml" > "$WORK/exprs"
[ -s "$WORK/exprs" ] || fail "no alert expressions found in alerts.yml"

checked=0
while IFS= read -r ref; do
  name="${ref%%\{*}"
  grep -qE "^${name}(\{| )" "$WORK/exposition" || fail "alerts.yml uses $name, which is not emitted"
  checked=$((checked + 1))
  [ "$ref" != "$name" ] || continue
  matchers="${ref#*\{}"; matchers="${matchers%\}}"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    label="${m%%[=!~]*}"; op="${m#"$label"}"; op="${op%%\"*}"; value="${m#*\"}"; value="${value%\"}"
    case "$op" in
      =)  alts="$value" ;;
      =~) alts=$(tr '|' '\n' <<<"$value") ;;
      *)  fail "alerts.yml: unsupported matcher '$m' on $name" ;;
    esac
    while IFS= read -r a; do
      grep -qE "^${name}\{([^}]*,)?${label}=\"${a}\"" "$WORK/exposition" \
        || fail "alerts.yml: $name{$label$op\"$value\"}: no sample with $label=\"$a\""
    done <<<"$alts"
  done < <(tr ',' '\n' <<<"$matchers" | sed 's/^ *//; s/ *$//')
done < <(grep -oE 'unbound_[a-z0-9_]+(\{[^}]*\})?' "$WORK/exprs" | sort -u)
pass "alerts.yml: $checked metric references, all emitted with the label values they match"
