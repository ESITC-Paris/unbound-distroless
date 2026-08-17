# syntax=docker/dockerfile:1

# Base images are parameterised so CI can pin them by digest (the digests live
# in .build-state.json, which the upstream monitor keeps current). Local builds
# get the floating tags, which is what the README documents.
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
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates \
      libevent-dev libssl-dev libexpat1-dev \
      libnghttp2-dev libhiredis-dev \
      libcap2-bin

WORKDIR /build

# Download, verify (supply-chain gate), build with hardening flags.
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
      --sysconfdir=/etc/unbound \
      --disable-chroot \
      --enable-pie \
      --enable-relro-now \
 && make -j"$(nproc)" \
 && make install

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
# 0-byte status.d entry literally named "diversion by libc6 from".
RUN set -eux; \
    triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
    mkdir -p "/deps/lib/$triplet" /deps/status.d /deps/certs; \
    : > /tmp/libs; \
    for b in /opt/unbound/sbin/*; do \
      ldd "$b" | awk '{print $3}' | grep -E '^/' >> /tmp/libs || true; \
      ldd "$b" | awk '/ld-linux/ {print $1}' >> /tmp/libs || true; \
    done; \
    sort -u /tmp/libs | while read -r lib; do \
      cp -L "$lib" "/deps/lib/$triplet/$(basename "$lib")"; \
      pkg="$( (dpkg -S "$lib" 2>/dev/null || dpkg -S "$(readlink -f "$lib")" 2>/dev/null) | grep -v '^diversion' | cut -d: -f1 | head -n1 )" || true; \
      if [ -n "$pkg" ]; then dpkg -s "$pkg" > "/deps/status.d/$pkg" 2>/dev/null || true; fi; \
    done; \
    cp -aL /etc/ssl/certs /deps/certs/


# ── Stage 2: distroless runtime ──────────────────────────────────────────────
FROM ${DISTROLESS_BASE}

ARG UNBOUND_VERSION
LABEL org.opencontainers.image.title="unbound-distroless" \
      org.opencontainers.image.description="Hardened, DNSSEC-validating Unbound DNS resolver on a distroless base" \
      org.opencontainers.image.source="https://github.com/ESITC-Paris/unbound-distroless" \
      org.opencontainers.image.version="${UNBOUND_VERSION}" \
      org.opencontainers.image.licenses="BSD-3-Clause AND MIT" \
      org.opencontainers.image.vendor="ESITC Paris"

COPY --from=build /opt/unbound /usr/local
COPY --from=build /etc/unbound /etc/unbound
COPY --from=build --chown=65532:65532 /staging/var-lib-unbound /var/lib/unbound
COPY --from=build --chown=65532:65532 /staging/run-unbound /run/unbound
COPY --from=build /deps/lib /usr/lib
COPY --from=build /deps/status.d /var/lib/dpkg/status.d
COPY --from=build /deps/certs/certs /etc/ssl/certs

# No LD_LIBRARY_PATH: every runtime library (including libunbound.so.8) is
# harvested into /usr/lib/<triplet>, a default trusted search dir. The main
# binary carries cap_net_bind_service, so it runs AT_SECURE and would ignore
# LD_LIBRARY_PATH anyway — relying on it would only work for the helper tools.

USER nonroot

EXPOSE 53/udp 53/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/usr/local/sbin/unbound-control", "-c", "/etc/unbound/unbound.conf", "status"]

ENTRYPOINT ["/usr/local/sbin/unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
