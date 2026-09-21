# shellcheck shell=bash
# Cache preservation across a swap.
#
# Recreating the resolver empties its cache: for the next minutes every
# popular name costs a round trip upstream, and serve-expired has nothing to
# serve. So the cache of the outgoing container is exported (dump_cache) just
# before the swap and imported (load_cache) into the new one once it has
# PASSED its post-swap validation — the gate always judges the new resolver on
# its own, never on data carried over.
#
# Best effort by construction: every failure here costs a cold cache, never
# the update. Nothing in this file may fail the cycle.
#
# Guards, all measured on unbound 1.26 before being set:
#   * same unbound major.minor only. The text format of dump_cache has been
#     stable for years, but nothing promises it; a cold cache is the safe
#     default across a larger jump.
#   * KEEP_CACHE_MAX_ENTRIES (500 000). The export runs in one command on one
#     worker thread of the OUTGOING resolver, which stops answering its share
#     of queries meanwhile: 0.8 s per 100 000 entries.
#   * import in batches of KEEP_CACHE_CHUNK entries. One monolithic
#     load_cache of 100 000 entries held a worker thread for 4.7 s (clients
#     hashed to it waited as long); batches of 5 000 kept every answer under
#     140 ms for 7 s in total.
#   * KEEP_CACHE_TIMEOUT (120 s) bounds each side; whatever is loaded by then
#     stays, the rest is left to prefetch and ordinary traffic.
#
# The dump holds the names clients asked for. It lives in the sidecar's /tmp
# only for the duration of the cycle and is removed on every exit path.

: "${KEEP_CACHE:=1}"
: "${KEEP_CACHE_MAX_ENTRIES:=500000}"
: "${KEEP_CACHE_CHUNK:=2000}"
: "${KEEP_CACHE_TIMEOUT:=120}"
CACHE_NOTE=""

_cache_ctl() {
  local c=$1; shift
  docker exec -i "$c" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf "$@"
}

# _cache_count <container> — rrset.cache.count, or empty when unavailable.
_cache_count() {
  timeout 15 docker exec "$1" /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf \
    stats_noreset 2>/dev/null | awk -F= '$1 == "rrset.cache.count" { print $2 }' || true
}

# cache_compatible <running_ref> <declared_ref> — true when a dump from the
# first can be loaded into the second: same reference (configuration-only
# cycle), or both carry a version label with the same major.minor.
cache_compatible() {
  [ "$1" = "$2" ] && return 0
  local a b
  a=$(image_version_label "$1"); b=$(image_version_label "$2")
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$(printf '%s' "$a" | cut -d. -f1,2)" = "$(printf '%s' "$b" | cut -d. -f1,2)" ]
}

# cache_save <container> <file> — exports the cache; false (and no file) when
# it is too large, unavailable or incomplete.
cache_save() {
  local c=$1 f=$2 n t0
  n=$(_cache_count "$c")
  case "$n" in
    '' | *[!0-9]*) log_warn "cache not preserved: statistics unavailable"; return 1 ;;
  esac
  if [ "$n" -gt "$KEEP_CACHE_MAX_ENTRIES" ]; then
    log_warn "cache not preserved: $n entries exceed KEEP_CACHE_MAX_ENTRIES=$KEEP_CACHE_MAX_ENTRIES"
    return 1
  fi
  t0=$(date +%s)
  if ! timeout "$KEEP_CACHE_TIMEOUT" docker exec "$c" /usr/local/sbin/unbound-control \
         -c /etc/unbound/unbound.conf dump_cache > "$f" 2>/dev/null \
     || [ "$(tail -n 1 "$f")" != EOF ]; then
    log_warn "cache not preserved: export failed or incomplete"
    rm -f "$f"
    return 1
  fi
  log_info "cache exported: $n record sets in $(( $(date +%s) - t0 ))s"
}

# _cache_split <dump> <dir> — cuts a dump into self-contained load_cache
# inputs of at most KEEP_CACHE_CHUNK entries each, numbered so that every
# record-set batch sorts before every message batch: a cached message only
# loads when the record sets it points to are already in the cache.
_cache_split() {
  awk -v dir="$2" -v size="$KEEP_CACHE_CHUNK" '
    function open_chunk(kind) {
      if (out != "") close_chunk()
      out = sprintf("%s/%06d", dir, ++chunks); cur = kind; cnt = 0
      print "START_RRSET_CACHE" > out
      if (kind == "m") { print "END_RRSET_CACHE" > out; print "START_MSG_CACHE" > out }
    }
    function close_chunk() {
      if (cur == "r") { print "END_RRSET_CACHE" > out; print "START_MSG_CACHE" > out }
      print "END_MSG_CACHE" > out; print "EOF" > out; close(out); out = ""
    }
    $0 == "START_RRSET_CACHE" { sec = "r"; next }
    $0 == "START_MSG_CACHE"   { sec = "m"; next }
    $0 == "END_RRSET_CACHE" || $0 == "END_MSG_CACHE" || $0 == "EOF" { sec = ""; next }
    sec != "" {
      head = (sec == "r") ? ($1 == ";rrset") : ($1 == "msg")
      if (head && (out == "" || cur != sec || cnt >= size)) open_chunk(sec)
      if (out == "") next
      if (head) cnt++
      print > out
    }
    END { if (out != "") close_chunk() }' "$1"
}

# cache_restore <container> <file> — imports a dump in batches; sets
# CACHE_NOTE for the notification. Never fails the caller.
cache_restore() {
  local c=$1 f=$2 dir part out ok=0 total=0 t0 deadline n
  [ -s "$f" ] || return 0
  dir=$(mktemp -d) || return 0
  _cache_split "$f" "$dir" || { rm -rf "$dir"; log_warn "cache not restored: dump unreadable"; return 0; }
  t0=$(date +%s); deadline=$(( t0 + KEEP_CACHE_TIMEOUT ))
  for part in "$dir"/*; do
    [ -e "$part" ] || continue
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log_warn "cache restore stopped at its ${KEEP_CACHE_TIMEOUT}s budget"
      break
    fi
    total=$(( total + 1 ))
    out=$(timeout 30 docker exec -i "$c" /usr/local/sbin/unbound-control \
            -c /etc/unbound/unbound.conf load_cache < "$part" 2>&1) || true
    [ "$out" = ok ] && ok=$(( ok + 1 ))
  done
  rm -rf "$dir"
  n=$(_cache_count "$c")
  log_info "cache restored: $ok/$total batches accepted, ${n:-?} record sets cached, in $(( $(date +%s) - t0 ))s"
  # shellcheck disable=SC2034  # read by unbound-autoupdate for the notification
  [ "$ok" -gt 0 ] && CACHE_NOTE=" The resolver cache was carried over (${n:-?} record sets)."
  return 0
}
