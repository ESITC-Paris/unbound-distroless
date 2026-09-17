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
    # unbound 1.26 prints the queue-time maximum in MICROseconds
    # (total.query.queue_time_us.max). Passed through verbatim it becomes
    # unbound_query_queue_time_us_max, which promlint rejects twice over: an
    # abbreviated unit, and not the base unit Prometheus mandates. Converted
    # to seconds here, and carrying the same "stat" label as the recursion
    # times below rather than a _max suffix, so the two time families in this
    # exposition have one shape.
    if (k ~ /^thread[0-9]+\.query\.queue_time_us\.max$/) {
      t=k; sub(/^thread/, "", t); sub(/\..*$/, "", t)
      family("unbound_thread_query_queue_time_seconds", "gauge", "Per-thread longest time a query waited in the queue, in seconds.")
      sample("unbound_thread_query_queue_time_seconds", "thread=\"" t "\",stat=\"max\"", sprintf("%.6f", v / 1000000)); next
    }
    if (k == "total.query.queue_time_us.max") {
      family("unbound_query_queue_time_seconds", "gauge", "Longest time a query waited in the queue, in seconds.")
      sample("unbound_query_queue_time_seconds", "stat=\"max\"", sprintf("%.6f", v / 1000000)); next
    }
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

# _prom_escape <value> — a label VALUE is a quoted string, and the three
# characters the exposition format does not allow raw inside one are a
# backslash, a double quote and a newline. One of them unescaped does not
# corrupt a single sample: it makes a Prometheus parser reject the WHOLE
# document, so every metric in this file is lost at once. stats_to_prometheus
# escapes its label values in awk for exactly that reason; the values below —
# an image digest, an image version label — come from image metadata, which is
# no more a trusted schema than unbound's control socket, and were printed raw.
_prom_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
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

  # Every label value below that is not drawn from CYCLE_STATUSES (a fixed
  # literal list record_cycle validates against) is attacker-influenced text.
  version=$(_prom_escape "$version")
  self_digest=$(_prom_escape "${self_digest:-unknown}")
  target=$(_prom_escape "${target:-unknown}")
  target_v=$(_prom_escape "${target_v:-unknown}")

  tmp=$(mktemp "$STATE_DIR/.metrics.XXXXXX")
  {
    printf '# HELP unbound_autoupdate_info Sidecar version and image digest.\n# TYPE unbound_autoupdate_info gauge\n'
    printf 'unbound_autoupdate_info{version="%s",image_digest="%s"} 1\n' "$version" "$self_digest"
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
    printf 'unbound_autoupdate_target_image_info{digest="%s",version="%s"} 1\n' "$target" "$target_v"
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

# _collect_stats — discover the resolver, then dump one
# `unbound-control stats_noreset` on stdout. Split out of the metrics CGI so
# the WHOLE collection, DISCOVERY INCLUDED, runs under one `timeout`:
# discovery makes several calls to the Docker socket (`docker ps`,
# `docker inspect`), and a wedged daemon hangs those exactly as surely as it
# hangs `docker exec` — bounding only the exec left the scrape able to hang
# forever on the step before it, which is the one failure a scrape must
# always survive.
#
# Dies (log_die) when the resolver cannot be found, which is why the CGI runs
# this in a child of its own: the scrape must still answer 200.
#
# `exec`, deliberately: this runs as the direct child of a `timeout`, and only
# that direct child is signalled when the budget runs out. Replacing the shell
# with docker exec puts the process timeout can actually kill at the end of
# the pipe, instead of leaving a stranded `docker exec` behind on every
# timed-out scrape. NOTHING may follow this call.
_collect_stats() {
  discover_target_container
  exec docker exec "$TARGET_CONTAINER" \
    /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset
}

# exec_metrics_server — busybox httpd in the foreground, docroot www/, with
# a proxy rule so the public path is /metrics rather than /cgi-bin/metrics.
# httpd is the process; tini forwards SIGTERM to it.
exec_metrics_server() {
  local port="${METRICS_PORT:-9167}" conf=/tmp/httpd.conf
  case "$port" in ''|*[!0-9]*) log_die "invalid METRICS_PORT: $port";; esac
  sed "s/@PORT@/$port/" "$_LIB_DIR/www/httpd.conf.tmpl" > "$conf"
  log_info "unbound-autoupdate $(cat "$_LIB_DIR/VERSION" 2>/dev/null || echo dev) metrics mode: serving /metrics on port $port"
  exec httpd -f -p "$port" -h "$_LIB_DIR/www" -c "$conf"
}
