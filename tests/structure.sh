#!/usr/bin/env bash
# Structure tests: verify image invariants without running the daemon.
# Usage: tests/structure.sh [image-tag]
set -euo pipefail

IMG="${1:-unbound-distroless:test}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v docker >/dev/null || fail "docker not found"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "image $IMG not found — build it first"

# 1. Runs as nonroot: the configured user is checked here, and resolved to a
#    numeric UID against the image's own /etc/passwd in section 5 (a name is
#    only as good as the passwd entry behind it).
USERCFG=$(docker image inspect -f '{{.Config.User}}' "$IMG")
[ -n "$USERCFG" ] || fail "image has no USER (would run as root)"
pass "configured user: $USERCFG"

# 2. Entrypoint and healthcheck
EP=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$IMG")
echo "$EP" | grep -q '/usr/local/sbin/unbound' || fail "unexpected entrypoint: $EP"
HC=$(docker image inspect -f '{{json .Config.Healthcheck}}' "$IMG")
echo "$HC" | grep -q 'unbound-control' || fail "healthcheck missing or wrong: $HC"
pass "entrypoint + healthcheck configured"

# 3. Exposed ports
PORTS=$(docker image inspect -f '{{json .Config.ExposedPorts}}' "$IMG")
echo "$PORTS" | grep -q '53/udp' || fail "53/udp not exposed"
echo "$PORTS" | grep -q '53/tcp' || fail "53/tcp not exposed"
pass "port 53 exposed (udp+tcp)"

# 4. Filesystem contents via export (image has no shell to exec into). The
#    export is unpacked once: the listing drives the path assertions, the
#    tree the content assertions (passwd, private keys, licence files).
CID=$(docker create "$IMG")
ROOTFS=$(mktemp -d)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true; chmod -R u+rwX "$ROOTFS" 2>/dev/null; rm -rf "$ROOTFS"' EXIT
docker export "$CID" > "$ROOTFS.tar"
LIST=$(tar -tf "$ROOTFS.tar")
# Verbose listing for ownership. GNU tar prints "uid/gid" in field 2, bsdtar
# (macOS) prints uid and gid as fields 3 and 4; normalise to "path uid/gid".
OWNERS=$(tar --numeric-owner -tvf "$ROOTFS.tar" \
  | awk '{ if ($2 ~ /^[0-9]+\/[0-9]+$/) o = $2; else o = $3 "/" $4; print $NF, o }')
# Unprivileged extraction: owners and file capabilities are not restored
# (not needed — only contents are read), device nodes are skipped.
tar -xf "$ROOTFS.tar" -C "$ROOTFS" 2>/dev/null || true
rm -f "$ROOTFS.tar"

# Feed $LIST via a here-string, not a pipe: `grep -q` exits at the first match,
# which kills `echo` with SIGPIPE, and `set -o pipefail` then turns a successful
# match into a spurious failure whenever the match is early enough in the list.
must_have() { grep -qE "$1" <<<"$LIST" || fail "missing from image: $1"; }
must_not_have() { grep -qE "$1" <<<"$LIST" && fail "must NOT be in image: $1" || true; }

must_have '^usr/local/sbin/unbound$'
must_have '^usr/local/sbin/unbound-control$'
must_have '^usr/local/sbin/unbound-anchor$'
must_have '^usr/local/sbin/unbound-checkconf$'
must_have '^etc/unbound/unbound.conf$'
must_have '^etc/unbound/root.hints$'
must_have '^var/lib/unbound/root.key$'
must_have '^run/unbound/$'
must_have '^etc/ssl/certs/ca-certificates.crt$'
must_have '^etc/passwd$'
# Harvested runtime libs live in the multiarch triplet dir (usr/lib/<triplet>/),
# which is where the ELF interpreter path resolves and the first default search
# dir — so the harvested loader and libc replace the base's as one coherent set.
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libevent'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libnghttp2'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libhiredis'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libprotobuf-c\.so\.1$'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libc\.so\.6$'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/ld-linux-'
must_have '^usr/lib/[^/]+-linux-gnu[^/]*/libunbound\.so\.8$'
must_have '^var/lib/dpkg/status.d/'
# dnstap's library must be visible to scanners like every other harvested one.
must_have '^var/lib/dpkg/status.d/libprotobuf-c1$'
pass "expected files present"

# No stale flat copies shadowed by / shadowing the triplet dir, and no dpkg
# diversion junk. (usr/lib/ld-linux-* may legitimately exist as the base's
# symlink into the triplet dir on arm64, so it is not checked here.)
must_not_have '^usr/lib/lib(event|c\.so\.6|crypto|ssl|expat|unbound|protobuf-c)'
must_not_have '^var/lib/dpkg/status.d/diversion'
# A baked root zone outlives its signatures and is then never replaced.
must_not_have '^var/lib/unbound/root.zone$'
pass "no flat lib copies shadowing the triplet dir, no dpkg diversion junk"

# 5. Effective UID: resolve the configured user against the image's own
#    /etc/passwd (and /etc/group for a name in the group part). The
#    distroless convention is nonroot = 65532:65532; the volume layout
#    (/var/lib/unbound, /run/unbound owned by 65532) depends on it.
resolve_id() {  # resolve_id <file> <name-or-number>
  case "$2" in
    ''|*[!0-9]*) awk -F: -v n="$2" '$1 == n { print $3; exit }' "$1" ;;
    *) echo "$2" ;;
  esac
}
U_PART=${USERCFG%%:*}
UID_NUM=$(resolve_id "$ROOTFS/etc/passwd" "$U_PART")
[ -n "$UID_NUM" ] || fail "user '$U_PART' has no entry in the image's /etc/passwd"
[ "$UID_NUM" = "65532" ] || fail "user '$USERCFG' resolves to UID $UID_NUM, expected 65532"
if [ "$USERCFG" != "$U_PART" ]; then
  GID_NUM=$(resolve_id "$ROOTFS/etc/group" "${USERCFG#*:}")
else
  GID_NUM=$(awk -F: -v u="$UID_NUM" '$3 == u { print $4; exit }' "$ROOTFS/etc/passwd")
fi
[ "$GID_NUM" = "65532" ] || fail "user '$USERCFG' resolves to GID '$GID_NUM', expected 65532"
for d in var/lib/unbound/ var/lib/unbound/root.key run/unbound/; do
  OWNER=$(awk -v p="$d" '$1 == p { print $2; exit }' <<<"$OWNERS")
  [ "$OWNER" = "65532/65532" ] || fail "/$d is owned by '$OWNER', expected 65532/65532"
done
pass "user '$USERCFG' resolves to 65532:65532 and owns /var/lib/unbound, /run/unbound"

# 6. No shell, no package manager — by allowlist where it matters most: the
#    only executables on any PATH-like directory are Unbound's own. Debian 13
#    is merged-/usr, so bin and sbin are symlinks in the tar stream and their
#    contents appear under usr/.
ALLOWED_BIN='unbound|unbound-anchor|unbound-checkconf|unbound-control|unbound-host'
ON_PATH=$(grep -E '^(usr/)?(local/)?s?bin/[^/]+$' <<<"$LIST" || true)
UNEXPECTED=$(grep -vE "/($ALLOWED_BIN)\$" <<<"$ON_PATH" | grep -v '^$' || true)
[ -z "$UNEXPECTED" ] || fail "unexpected entries on PATH-like dirs: $(echo "$UNEXPECTED" | tr '\n' ' ')"
# ...and by name anywhere else, so a shell or package manager parked in, say,
# usr/lib or usr/libexec is caught too.
SHELLS='sh|bash|rbash|dash|ash|zsh|ksh|ksh93|mksh|pdksh|lksh|csh|tcsh|fish|yash|posh|busybox|toybox'
PKGMGRS='apt|apt-get|apt-cache|aptitude|dpkg|dpkg-deb|dpkg-query|apk|rpm|yum|dnf|microdnf|zypper|pacman|pip|pip3'
HITS=$(grep -E "(^|/)($SHELLS|$PKGMGRS)\$" <<<"$LIST" || true)
[ -z "$HITS" ] || fail "shell or package manager in image: $(echo "$HITS" | tr '\n' ' ')"
must_not_have '^usr/lib/apt/'
must_not_have '^etc/apt/'
pass "no shell, no package manager (PATH dirs hold only: $(echo "$ON_PATH" | sed 's|.*/||' | tr '\n' ' '))"

# 6b. Every executable on those dirs can actually run here: a script would
#     need an interpreter the image does not have (unbound-control-setup, a
#     /bin/sh script, used to ship and could never run). Static check: a
#     regular ELF file, not a symlink or "#!" script. Dynamic check: the
#     kernel/runtime can exec it (`-h` only prints usage; the exit status of
#     the tool itself is irrelevant, an exec failure is not).
for e in $ON_PATH; do
  f="$ROOTFS/$e"
  { [ -f "$f" ] && [ ! -L "$f" ]; } || fail "/$e is not a regular file"
  MAGIC=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')
  [ "$MAGIC" = "7f454c46" ] || fail "/$e is not an ELF executable (magic $MAGIC): it cannot run without an interpreter"
  OUT=$(docker run --rm --network none --entrypoint "/$e" "$IMG" -h 2>&1) && RC=0 || RC=$?
  case "$RC" in 125|126|127) fail "/$e cannot be executed in the image (docker run rc=$RC): $OUT" ;; esac
  grep -qiE 'exec .*(no such file|exec format error|permission denied|operation not permitted)' <<<"$OUT" \
    && fail "/$e cannot be executed in the image: $OUT"
done
pass "every executable on PATH dirs is ELF and runs in the image"

# 7. No private key material anywhere: content scan of every regular file
#    (PEM and OpenSSH private keys, any algorithm), plus the names
#    unbound-control-setup generates. The control channel is a unix socket, so
#    the image needs no key at all; a baked-in key would be shared by every
#    deployment.
KEYS=$(grep -rlaE -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' "$ROOTFS" 2>/dev/null | sed "s|^$ROOTFS/||" || true)
[ -z "$KEYS" ] || fail "private key material in image: $(echo "$KEYS" | tr '\n' ' ')"
must_not_have '(^|/)unbound_(server|control)\.(key|pem)$'
must_not_have '(^|/)ssh_host_[^/]*_key$'
pass "no private key material (content scan of every file)"

# 8. Licence notices: every package recorded in the dpkg status.d database
#    ships its copyright file, and Unbound's own LICENSE is present. These are
#    regular, non-empty files (a symlink could point outside the image).
PKGS=$(grep -E '^var/lib/dpkg/status.d/[^/]+$' <<<"$LIST" | sed 's|.*/||' | grep -v '\.md5sums$')
[ -n "$PKGS" ] || fail "no packages in var/lib/dpkg/status.d"
for p in $PKGS; do
  f="$ROOTFS/usr/share/doc/$p/copyright"
  { [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ]; } || fail "package $p has no /usr/share/doc/$p/copyright"
done
f="$ROOTFS/usr/share/doc/unbound/LICENSE"
{ [ -f "$f" ] && [ ! -L "$f" ] && grep -q 'NLnet Labs' "$f"; } || fail "Unbound's LICENSE missing at /usr/share/doc/unbound/LICENSE"
# This repository's MIT files (unbound.conf) need their own notice, and NOTICE
# states the scope of the image's licenses label; both must be the repo's.
HERE=$(cd "$(dirname "$0")" && pwd)
for n in LICENSE NOTICE; do
  f="$ROOTFS/usr/share/doc/unbound-distroless/$n"
  { [ -f "$f" ] && [ ! -L "$f" ]; } || fail "/usr/share/doc/unbound-distroless/$n missing"
  cmp -s "$f" "$HERE/../$n" || fail "/usr/share/doc/unbound-distroless/$n differs from the repository's $n"
done
pass "licence notices: $(echo "$PKGS" | wc -l | tr -d ' ') packages with copyright files + Unbound LICENSE + this repo's LICENSE/NOTICE"

echo "ALL STRUCTURE TESTS PASSED"
