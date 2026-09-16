#!/usr/bin/env bash
# Prometheus exposition: conversion of `unbound-control stats_noreset` and
# the sidecar's own cycle metrics. The text format's reference parser
# (promtool) is what the tests hold this output to.

METRICS_FILE="${STATE_DIR:-/var/lib/unbound-autoupdate}/metrics.prom"
_LIB_DIR=/usr/local/lib/unbound-autoupdate
CYCLE_STATUSES="up_to_date updated check_ok skipped blocked rollback critical error"

# stats_to_prometheus — stdin: key=value lines from unbound-control;
# stdout: exposition text. Families are buffered and printed grouped, each
# with HELP and TYPE exactly once. unbound's histogram buckets are counts per
# range; Prometheus wants cumulative counts per upper bound.
stats_to_prometheus() {
  awk -F= '
  function sanitize(s) { gsub(/[^a-zA-Z0-9_]/, "_", s); return s }
  # esc — label VALUES are quoted strings: a backslash or a double quote in a
  # statistic name (unbound prints unknown RR types as TYPE<n>, and the socket
  # is not a trusted schema) would otherwise break out of the label and make
  # the whole document unparseable. Doubled replacements on purpose: gsub eats
  # one level of backslash in the replacement text itself.
  function esc(s) { gsub(/\\/, "\\\\\\\\", s); gsub(/"/, "\\\\\"", s); return s }
  function family(name, type, help) {
    if (!(name in ftype)) { ftype[name]=type; fhelp[name]=help; forder[++nf]=name }
  }
  function sample(name, labels, value,   line) {
    line = name
    if (labels != "") line = line "{" labels "}"
    fsamples[name] = fsamples[name] line " " value "\n"
  }
  function labelled(key, prefix, name, type, help, label,   l) {
    l = key; sub("^" prefix, "", l)
    family(name, type, help); sample(name, label "=\"" esc(l) "\"", $2)
  }
  {
    # unbound-control also prints free-form text (a failed connection, a blank
    # line). A record with no value would become a value-less sample, which
    # makes a Prometheus parser reject the ENTIRE document — every other
    # metric lost precisely when something is already going wrong. Drop it.
    if (NF < 2 || $1 == "") next
    k=$1; v=$2
    if (k ~ /^thread[0-9]+\./) {
      t=k; sub(/^thread/, "", t); sub(/\..*$/, "", t)
      rest=k; sub(/^thread[0-9]+\./, "", rest)
      # The num.* keys of a thread are monotonic counts, so they are counters
      # and promlint requires the _total suffix; everything else (requestlist
      # depths, tcpusage) is a gauge and must NOT carry it.
      if (rest ~ /^num\./) {
        sub(/^num\./, "", rest)
        n="unbound_thread_" sanitize(rest) "_total"
        family(n, "counter", "Per-thread count of " rest " from unbound-control stats.")
      } else {
        n="unbound_thread_" sanitize(rest)
        family(n, "gauge", "Per-thread value of " rest " from unbound-control stats.")
      }
      sample(n, "thread=\"" t "\"", v); next
    }
    if (k ~ /^num\.query\.type\./)       { labelled(k, "num.query.type.",       "unbound_query_types_total",      "counter", "Queries received, by query type.", "type");   next }
    if (k ~ /^num\.query\.class\./)      { labelled(k, "num.query.class.",      "unbound_query_classes_total",    "counter", "Queries received, by query class.", "class"); next }
    if (k ~ /^num\.query\.opcode\./)     { labelled(k, "num.query.opcode.",     "unbound_query_opcodes_total",    "counter", "Queries received, by opcode.", "opcode");     next }
    if (k ~ /^num\.query\.flags\./)      { labelled(k, "num.query.flags.",      "unbound_query_flags_total",      "counter", "Queries received, by flag.", "flag");         next }
    if (k ~ /^num\.query\.aggressive\./) { labelled(k, "num.query.aggressive.", "unbound_query_aggressive_total", "counter", "Answers synthesised from cached NSEC/NSEC3 (RFC 8198), by rcode.", "rcode"); next }
    if (k ~ /^num\.answer\.rcode\./)     { labelled(k, "num.answer.rcode.",     "unbound_answer_rcodes_total",    "counter", "Answers sent, by rcode.", "rcode");           next }
    if (k == "num.answer.secure") { family("unbound_answers_secure_total", "counter", "Answers that validated as DNSSEC secure."); sample("unbound_answers_secure_total", "", v); next }
    if (k == "num.answer.bogus")  { family("unbound_answers_bogus_total",  "counter", "Answers that failed DNSSEC validation (bogus).");   sample("unbound_answers_bogus_total",  "", v); next }
    if (k == "num.rrset.bogus")   { family("unbound_rrset_bogus_total",    "counter", "RRsets marked bogus by the validator.");           sample("unbound_rrset_bogus_total",    "", v); next }
    if (k ~ /^histogram\./) {
      hi=k; sub(/^histogram\.[0-9]+\.[0-9]+\.to\./, "", hi)
      hcount[++nh]=v; hle[nh]=hi+0; next
    }
    if (k == "total.recursion.time.avg" || k == "total.recursion.time.median") {
      # The label is "stat", not "quantile": avg is not a quantile at all, and
      # the exposition format reserves "quantile" for summaries, whose label
      # values must parse as floats ("median" does not).
      q=k; sub(/^total\.recursion\.time\./, "", q)
      if (q == "avg") ravg=v
      family("unbound_recursion_time_seconds", "gauge", "Recursion time of answers that needed recursion, in seconds.")
      sample("unbound_recursion_time_seconds", "stat=\"" q "\"", v); next
    }
    if (k == "total.num.recursivereplies") rreplies=v
    if (k ~ /^total\./) {
      rest=k; sub(/^total\./, "", rest)
      # Same split as the per-thread families: total.num.* are counters and
      # get the _total suffix promlint insists on, the rest are gauges.
      if (rest ~ /^num\./) {
        sub(/^num\./, "", rest)
        n="unbound_" sanitize(rest) "_total"
        family(n, "counter", "Count of " rest " across all threads, from unbound-control stats.")
      } else {
        n="unbound_" sanitize(rest)
        family(n, "gauge", "Value of " rest " across all threads, from unbound-control stats.")
      }
      sample(n, "", v); next
    }
    if (k ~ /^time\.(now|up|elapsed)$/) {
      rest=k; sub(/^time\./, "", rest); n="unbound_time_" rest "_seconds"
      family(n, "gauge", "Unbound time." rest ", in seconds."); sample(n, "", v); next
    }
    if (k ~ /^mem\./) {
      rest=k; sub(/^mem\./, "", rest); n="unbound_mem_" sanitize(rest) "_bytes"
      family(n, "gauge", "Memory in use by " rest ", in bytes."); sample(n, "", v); next
    }
    if (k ~ /^(msg|rrset|infra|key)\.cache\.count$/) {
      # "unbound_cache_count" would be read as a histogram/summary companion
      # series by the naming rules of the exposition format; "entries" says the
      # same thing and lints clean.
      c=k; sub(/\.cache\.count$/, "", c)
      family("unbound_cache_entries", "gauge", "Number of entries per cache."); sample("unbound_cache_entries", "cache=\"" esc(c) "\"", v); next
    }
    if (k == "unwanted.queries") { family("unbound_unwanted_queries_total", "counter", "Queries refused by access control.");            sample("unbound_unwanted_queries_total", "", v); next }
    if (k == "unwanted.replies") { family("unbound_unwanted_replies_total", "counter", "Unsolicited replies, a cache-poisoning signal."); sample("unbound_unwanted_replies_total", "", v); next }
    family("unbound_stat", "gauge", "Any other unbound-control statistic, by name.")
    sample("unbound_stat", "name=\"" esc(k) "\"", v)
  }
  END {
    for (i=1; i<=nf; i++) { n=forder[i]; printf "# HELP %s %s\n# TYPE %s %s\n%s", n, fhelp[n], n, ftype[n], fsamples[n] }
    if (nh > 0) {
      printf "# HELP unbound_response_time_seconds Recursion time distribution, in seconds.\n# TYPE unbound_response_time_seconds histogram\n"
      cum=0
      for (i=1; i<=nh; i++) { cum+=hcount[i]; printf "unbound_response_time_seconds_bucket{le=\"%g\"} %d\n", hle[i], cum }
      printf "unbound_response_time_seconds_bucket{le=\"+Inf\"} %d\n", cum
      printf "unbound_response_time_seconds_sum %g\n", (rreplies+0) * (ravg+0)
      printf "unbound_response_time_seconds_count %d\n", cum
    }
  }'
}

# write_cycle_metrics — rewrite metrics.prom from persisted state, atomically.
# Called at the end of every cycle (record_cycle) and by the self-update
# helper after it changed the sidecar itself.
write_cycle_metrics() {
  local tmp version self_digest status last_status last_ts last_dur target target_v s ts
  version=$(cat "$_LIB_DIR/VERSION" 2>/dev/null || echo dev)
  self_digest=$(docker image inspect "${SELF_IMAGE_ID:-}" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null) || self_digest=""
  last_status=$(state_get LAST_CYCLE_STATUS); : "${last_status:=error}"
  last_ts=$(state_get LAST_CYCLE_TS);         : "${last_ts:=0}"
  last_dur=$(state_get LAST_CYCLE_DURATION);  : "${last_dur:=0}"
  target=$(state_get LAST_IMAGE_DIGEST)
  target_v=""
  [ -n "$target" ] && target_v=$(docker image inspect "$target" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null) || true
  ts=$(state_get SELF_UPDATE_TS); : "${ts:=0}"

  tmp=$(mktemp "$STATE_DIR/.metrics.XXXXXX")
  {
    printf '# HELP unbound_autoupdate_info Sidecar version and image digest.\n# TYPE unbound_autoupdate_info gauge\n'
    printf 'unbound_autoupdate_info{version="%s",image_digest="%s"} 1\n' "$version" "${self_digest:-unknown}"
    printf '# HELP unbound_autoupdate_last_cycle_timestamp_seconds End of the last update cycle, unix time.\n# TYPE unbound_autoupdate_last_cycle_timestamp_seconds gauge\n'
    printf 'unbound_autoupdate_last_cycle_timestamp_seconds %s\n' "$last_ts"
    printf '# HELP unbound_autoupdate_last_cycle_duration_seconds Duration of the last update cycle.\n# TYPE unbound_autoupdate_last_cycle_duration_seconds gauge\n'
    printf 'unbound_autoupdate_last_cycle_duration_seconds %s\n' "$last_dur"
    printf '# HELP unbound_autoupdate_last_cycle_status Outcome of the last cycle, one-hot.\n# TYPE unbound_autoupdate_last_cycle_status gauge\n'
    for s in $CYCLE_STATUSES; do
      printf 'unbound_autoupdate_last_cycle_status{status="%s"} %d\n' "$s" "$([ "$s" = "$last_status" ] && echo 1 || echo 0)"
    done
    printf '# HELP unbound_autoupdate_cycles_total Cycles run since the state volume was created, by outcome.\n# TYPE unbound_autoupdate_cycles_total counter\n'
    for s in $CYCLE_STATUSES; do
      local c; c=$(state_get "CYCLES_${s^^}"); : "${c:=0}"
      printf 'unbound_autoupdate_cycles_total{status="%s"} %s\n' "$s" "$c"
    done
    printf '# HELP unbound_autoupdate_quarantine_active 1 while a failed image, configuration or sidecar image is held back.\n# TYPE unbound_autoupdate_quarantine_active gauge\n'
    printf 'unbound_autoupdate_quarantine_active{axis="image"} %d\n'  "$(_quarantine_window_open QUARANTINE_TS        && echo 1 || echo 0)"
    printf 'unbound_autoupdate_quarantine_active{axis="config"} %d\n' "$(_quarantine_window_open CONFIG_QUARANTINE_TS && echo 1 || echo 0)"
    printf 'unbound_autoupdate_quarantine_active{axis="self"} %d\n'   "$(_quarantine_window_open SELF_QUARANTINE_TS   && echo 1 || echo 0)"
    printf '# HELP unbound_autoupdate_target_image_info Image the resolver was last seen or deployed on.\n# TYPE unbound_autoupdate_target_image_info gauge\n'
    printf 'unbound_autoupdate_target_image_info{digest="%s",version="%s"} 1\n' "${target:-unknown}" "${target_v:-unknown}"
    printf '# HELP unbound_autoupdate_self_update_last_timestamp_seconds Last successful self-update, unix time (0 = never).\n# TYPE unbound_autoupdate_self_update_last_timestamp_seconds gauge\n'
    printf 'unbound_autoupdate_self_update_last_timestamp_seconds %s\n' "$ts"
  } > "$tmp"
  mv -f "$tmp" "$METRICS_FILE"
}

# record_cycle <status> <duration_seconds> — persist the outcome, bump its
# counter, rewrite metrics.prom. <status> must be one of CYCLE_STATUSES.
record_cycle() {
  local status="$1" duration="$2"
  case " $CYCLE_STATUSES " in *" $status "*) : ;; *) log_die "record_cycle: unknown status '$status'";; esac
  state_set LAST_CYCLE_STATUS "$status"
  state_set LAST_CYCLE_TS "$(date -u +%s)"
  state_set LAST_CYCLE_DURATION "$duration"
  state_inc "CYCLES_${status^^}"
  write_cycle_metrics
}

# Provisional stub, replaced by the real busybox-httpd server in the metrics
# task. Declared here so `entrypoint.sh metrics` fails by name rather than
# with an unbound-command error.
exec_metrics_server() { log_die "metrics mode: not implemented yet"; }
