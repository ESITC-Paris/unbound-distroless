# syntax=docker/dockerfile:1

# Base images are parameterised so CI can pin them by digest (the digests live
# in .build-state.json, which the upstream monitor keeps current).
#
# NON-REPRODUCIBLE DEFAULTS: the two floating tags below exist only so that a
# bare `docker build` still works. They resolve to whatever the registry
# serves today, so such a build is not the image CI tested or published. To
# build with exactly the pins CI uses (bases by digest, Unbound version and
# hash, image revision), run scripts/build.sh.
ARG DEBIAN_BASE=debian:trixie
ARG DISTROLESS_BASE=gcr.io/distroless/base-debian13:nonroot

# ── Stage 1: build Unbound from source on Debian and stage the runtime ───────
FROM ${DEBIAN_BASE} AS build

ARG UNBOUND_VERSION
ARG UNBOUND_SHA256
# Root data sources are overridable for mirrors/outages; the FTP fallbacks are
# InterNIC's documented alternate service (see the header of named.cache).
ARG ROOT_HINTS_URL=https://www.internic.net/domain/named.cache
ARG ROOT_HINTS_URL_FALLBACK=ftp://ftp.internic.net/domain/named.cache
ARG ROOT_ZONE_URL=https://www.internic.net/domain/root.zone
ARG ROOT_ZONE_URL_FALLBACK=ftp://ftp.internic.net/domain/root.zone
ENV DEBIAN_FRONTEND=noninteractive
# Pipelines in RUN must fail on the first broken stage, not the last.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Cache mounts keep apt archives/lists out of the image layers and speed up
# rebuilds; sharing=locked serialises the parallel amd64/arm64 builds.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
# `apt-get upgrade` before anything else: the runtime image's shared libraries
# (libc, zlib, zstd, OpenSSL, libevent, ...) are harvested from THIS stage
# below, and the copies — with their dpkg metadata — replace the distroless
# base's. The security state that ships is therefore this stage's, not the
# runtime base's. The base is digest-pinned so the *base* is reproducible;
# the upgrade then applies the Debian security updates published after that
# digest was cut, which the Trivy gate otherwise refuses as soon as a fix
# exists (v1.26.2-r2: zlib1g fixed in trixie-security, debian:trixie not yet
# rebuilt, release blocked). Rebuilds are still triggered by the monitor's
# digest tracking (upstream-check.yml), so the pin keeps moving forward.
#
# IMAGE_REVISION is the cache-bust contract with the release workflows, which
# pass the immutable tag being built (X.Y.Z-rN, from versions.env). A
# revision bump with an unchanged base digest — e.g. a rebuild for a fix
# published in trixie-security — would otherwise be a layer-cache hit
# (cache-from: type=gha) and ship the very libraries it was meant to replace.
# Referencing the ARG in this RUN changes its cache key, and every later step
# of this stage builds on top of this layer, so the source build and the root
# hints, root zone and trust anchor downloads below are redone for every new
# revision too. Same revision = same layers (re-running CI for one revision
# reuses its cache). Empty by default: a bare `docker build` still works and
# reuses its own local cache as usual.
ARG IMAGE_REVISION=
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    echo "image revision: ${IMAGE_REVISION:-unset (local build)}" \
 && apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates \
      libevent-dev libssl-dev libexpat1-dev \
      libnghttp2-dev libhiredis-dev \
      libprotobuf-c-dev protobuf-c-compiler \
      libcap2-bin

WORKDIR /build

# Download, verify (supply-chain gate), build with hardening flags.
#
# Where the OpenPGP check is: not here. The build only compares the tarball
# with UNBOUND_SHA256, and that pin is minted in exactly one place:
# .github/workflows/upstream-check.yml downloads the tarball and its .asc,
# imports the NLnet Labs signing key vendored at
# .github/keys/nlnetlabs-releases-g2.asc, refuses it unless its fingerprint is
# the one pinned in that workflow, runs `gpg --verify`, and only then writes
# the hash into versions.env (fail-closed). A hash match here therefore means
# "the exact bytes whose signature was verified". To redo it by hand:
#   curl -fsSLO https://nlnetlabs.nl/downloads/unbound/unbound-X.Y.Z.tar.gz
#   curl -fsSLO https://nlnetlabs.nl/downloads/unbound/unbound-X.Y.Z.tar.gz.asc
#   export GNUPGHOME="$(mktemp -d)"
#   gpg --import .github/keys/nlnetlabs-releases-g2.asc
#   gpg --fingerprint    # must match UNBOUND_SIGNING_KEY in upstream-check.yml
#   gpg --verify unbound-X.Y.Z.tar.gz.asc unbound-X.Y.Z.tar.gz
#   sha256sum unbound-X.Y.Z.tar.gz    # must equal UNBOUND_SHA256 in versions.env
#
# Features: DoH (nghttp2), cachedb + Redis/Valkey (hiredis), EDNS Client
# Subnet (--enable-subnet: compiled in, inert unless "subnetcache" is added to
# module-config) and dnstap logging (--enable-dnstap, off unless
# dnstap-enable is set). dnstap needs only libprotobuf-c at run time —
# Unbound writes Frame Streams itself (dnstap/dtstream.c), libfstrm is not
# used — and it is DT_NEEDED, so the ldd harvest below ships it.
# Trade-off accepted by design: DT_NEEDED also means libprotobuf-c is mapped
# into every resolver process even with dnstap off. Its code is only reached
# when dnstap encodes a message (it never parses network input here), so the
# added attack surface is small, and it is scanned by the Trivy gate like
# every other harvested library; in exchange dnstap works without a rebuild.
# DNS over QUIC is deliberately absent: Unbound needs ngtcp2's OpenSSL crypto
# helper (libngtcp2_crypto_ossl, or _quictls), and Debian trixie packages
# only the GnuTLS one (libngtcp2 1.11), so the link fails without vendoring
# a second ngtcp2 build.
# The LICENSE copy is the notice that BSD-3-Clause requires to travel with
# the binaries; it is shipped as /usr/share/doc/unbound/LICENSE.
# unbound-control-setup is removed: it is a /bin/sh script (no shell here, so
# it cannot run), and it only generates TLS keys for a TCP control channel,
# which this image does not use (control-interface is a unix socket).
# tests/structure.sh asserts every shipped executable actually runs.
RUN curl -fsSLO "https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz" \
 && echo "${UNBOUND_SHA256}  unbound-${UNBOUND_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf "unbound-${UNBOUND_VERSION}.tar.gz" \
 && cd "unbound-${UNBOUND_VERSION}" \
 && ./configure \
      --prefix=/opt/unbound \
      --with-libevent=/usr \
      --with-ssl=/usr \
      --with-libnghttp2 \
      --enable-cachedb \
      --with-libhiredis \
      --enable-subnet \
      --enable-dnstap \
      --sysconfdir=/etc/unbound \
      --disable-chroot \
      --enable-pie \
      --enable-relro-now \
 && make -j"$(nproc)" \
 && make install \
 && rm /opt/unbound/sbin/unbound-control-setup \
 && install -D -m 0644 LICENSE /deps/doc/unbound/LICENSE

# Allow binding port 53 as non-root (xattr survives COPY --from under BuildKit).
RUN setcap 'cap_net_bind_service=+ep' /opt/unbound/sbin/unbound

# Config, root hints, build-time validation.
COPY unbound.conf /etc/unbound/unbound.conf
RUN curl -fsSL --retry 3 --retry-delay 5 -o /etc/unbound/root.hints "$ROOT_HINTS_URL" \
 || curl -fsSL --retry 3 --retry-delay 5 -o /etc/unbound/root.hints "$ROOT_HINTS_URL_FALLBACK"

# Stage writable runtime dirs; generate the DNSSEC trust anchor fresh at build
# (unbound-anchor exits 1 when it updates the anchor — that is success).
# Also bake a current copy of the root zone (RFC 8806 hyperlocal root): the
# resolver starts warm from this file and thereafter keeps it fresh itself via
# AXFR/IXFR from the root servers (auth-zone in unbound.conf), persisting it
# in /var/lib/unbound alongside the trust anchor.
RUN mkdir -p /staging/var-lib-unbound /staging/run-unbound \
 && ( /opt/unbound/sbin/unbound-anchor -a /staging/var-lib-unbound/root.key -v || true ) \
 && test -s /staging/var-lib-unbound/root.key \
 && ( curl -fsSL --retry 3 --retry-delay 5 -o /staging/var-lib-unbound/root.zone "$ROOT_ZONE_URL" \
      || curl -fsSL --retry 3 --retry-delay 5 -o /staging/var-lib-unbound/root.zone "$ROOT_ZONE_URL_FALLBACK" ) \
 && head -1 /staging/var-lib-unbound/root.zone | grep -q 'IN.*SOA' \
 && chown -R 65532:65532 /staging/var-lib-unbound /staging/run-unbound \
 && ln -s /staging/var-lib-unbound /var/lib/unbound \
 && mkdir -p /run/unbound \
 && /opt/unbound/sbin/unbound-checkconf /etc/unbound/unbound.conf

# Harvest runtime shared libraries as SONAME-named regular files, plus their
# dpkg metadata so vulnerability scanners can see them, plus the CA bundle.
#
# LIMITATION — ldd only sees link-time (DT_NEEDED) dependencies, never
# libraries loaded at runtime via dlopen(). All currently enabled configure
# options are link-time, and the functional gate enforces that the
# dlopen-based ones stay off (see tests/functional.sh). If you ever enable
# --with-pythonmodule, --with-dynlibmodule, or non-default OpenSSL
# providers/engines, this harvest must be extended by hand with their
# runtime-loaded objects — and the gate assertion relaxed deliberately.
#
# Everything lands in the multiarch triplet directory (e.g. lib/x86_64-linux-gnu/)
# so that `COPY /deps/lib /usr/lib` in the runtime stage merges the harvest INTO
# /usr/lib/<triplet>, replacing the distroless base's own copies as one coherent
# set. That matters for the loader/libc pair: the ELF interpreter path is
# absolute (/lib64/ld-linux-x86-64.so.2 on amd64, /lib/ld-linux-aarch64.so.1 on
# arm64) and in both bases it is a symlink chain that terminates at the real file
# /usr/lib/<triplet>/ld-linux-*.so.* — so the harvested loader lands exactly
# where the interpreter path resolves. /usr/lib/<triplet> is also the FIRST entry
# in glibc's default (trusted) search path, so the harvested libc.so.6 is the one
# the harvested loader binds. Placing the libs flat in /usr/lib instead would
# leave the base's triplet-dir libc.so.6 shadowing the harvested one: a loader
# and a libc from two independently-updated sources.
#
# /usr/lib/<triplet> being a trusted default dir is also what keeps
# libunbound.so.8 resolvable for /usr/local/sbin/unbound, which carries a file
# capability and therefore runs AT_SECURE with LD_LIBRARY_PATH ignored.
#
# The `grep -v '^diversion'` drops the "diversion by libc6 from: ..." lines that
# `dpkg -S` prefixes to the real "pkg: path" hit; without it they produce a bogus
# 0-byte status.d entry literally named "diversion by libc6 from". It is
# applied to each lookup separately: for the loader's /lib path dpkg -S
# succeeds with ONLY a diversion line, so the canonical-path retry must run
# when the filtered result is empty, not when dpkg -S fails.
#
# Each harvested package also brings its /usr/share/doc/<pkg>/copyright: the
# licences of these libraries (BSD, MIT, Apache-2.0, LGPL, ...) require the
# notice to accompany the binaries, and the copy shipped must be the one of
# the version shipped (this stage's), not the base's. Fail-closed: a library
# outside /opt/unbound that no package owns, or a package without a copyright
# file, stops the build instead of shipping unaccounted-for code.
# tests/structure.sh asserts the pairing on the final image.
RUN set -eux; \
    triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
    mkdir -p "/deps/lib/$triplet" /deps/status.d /deps/certs /deps/doc; \
    : > /tmp/libs; \
    for b in /opt/unbound/sbin/*; do \
      ldd "$b" | awk '{print $3}' | grep -E '^/' >> /tmp/libs || true; \
      ldd "$b" | awk '/ld-linux/ {print $1}' >> /tmp/libs || true; \
    done; \
    sort -u /tmp/libs | while read -r lib; do \
      cp -L "$lib" "/deps/lib/$triplet/$(basename "$lib")"; \
      case "$lib" in /opt/unbound/*) continue ;; esac; \
      pkg="$(dpkg -S "$lib" 2>/dev/null | grep -v '^diversion' | cut -d: -f1 | head -n1)" || true; \
      [ -n "$pkg" ] || pkg="$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null | grep -v '^diversion' | cut -d: -f1 | head -n1)" || true; \
      [ -n "$pkg" ] || { echo "no dpkg package owns $lib" >&2; exit 1; }; \
      dpkg -s "$pkg" > "/deps/status.d/$pkg"; \
      install -D -m 0644 "/usr/share/doc/$pkg/copyright" "/deps/doc/$pkg/copyright"; \
    done; \
    cp -aL /etc/ssl/certs /deps/certs/


# ── Stage 2: distroless runtime ──────────────────────────────────────────────
FROM ${DISTROLESS_BASE}

ARG UNBOUND_VERSION
# licenses is deliberately SCOPED, not complete: it covers the software this
# project builds and authors — Unbound (BSD-3-Clause) and this repository's
# files, e.g. unbound.conf (MIT). The image also redistributes Debian
# packages (from the harvest and the distroless base) under many more
# licences, several without an SPDX identifier (glibc's copyright file alone
# has ~40 stanzas; media-types is "ad-hoc"), so no honest complete SPDX
# expression exists. The per-component list is NOTICE (shipped at
# /usr/share/doc/unbound-distroless/NOTICE); the authoritative texts are
# /usr/share/doc/*/copyright, asserted by tests/structure.sh.
# image.version carries the revision (X.Y.Z-rN) when the build is given one:
# the update sidecar compares it to refuse a downgrade to an older revision.
ARG IMAGE_REVISION=
LABEL org.opencontainers.image.title="unbound-distroless" \
      org.opencontainers.image.description="Hardened, DNSSEC-validating Unbound DNS resolver on a distroless base" \
      org.opencontainers.image.source="https://github.com/ESITC-Paris/unbound-distroless" \
      org.opencontainers.image.version="${IMAGE_REVISION:-${UNBOUND_VERSION}}" \
      org.opencontainers.image.licenses="BSD-3-Clause AND MIT" \
      org.opencontainers.image.vendor="ESITC Paris"

COPY --from=build /opt/unbound /usr/local
COPY --from=build /etc/unbound /etc/unbound
COPY --from=build --chown=65532:65532 /staging/var-lib-unbound /var/lib/unbound
COPY --from=build --chown=65532:65532 /staging/run-unbound /run/unbound
COPY --from=build /deps/lib /usr/lib
COPY --from=build /deps/status.d /var/lib/dpkg/status.d
COPY --from=build /deps/doc /usr/share/doc
COPY --from=build /deps/certs/certs /etc/ssl/certs
# This repository's own notice: unbound.conf (and the image recipe) are MIT,
# and NOTICE lists every redistributed component and the label's scope.
COPY LICENSE NOTICE /usr/share/doc/unbound-distroless/

# No LD_LIBRARY_PATH: every runtime library (including libunbound.so.8) is
# harvested into /usr/lib/<triplet>, a default trusted search dir. The main
# binary carries cap_net_bind_service, so it runs AT_SECURE and would ignore
# LD_LIBRARY_PATH anyway — relying on it would only work for the helper tools.

USER nonroot

EXPOSE 53/udp 53/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/usr/local/sbin/unbound-control", "-c", "/etc/unbound/unbound.conf", "status"]

ENTRYPOINT ["/usr/local/sbin/unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
