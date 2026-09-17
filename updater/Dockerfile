# syntax=docker/dockerfile:1

# Base images are parameterised so CI can pin them by digest (the digests live
# in .build-state.json, kept current by upstream-check.yml, which also
# triggers a rebuild when they move). Local builds get the floating tags.
ARG ALPINE_BASE=alpine:3.24
ARG COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v3.1.3

FROM ${COSIGN_IMAGE} AS cosign

FROM ${ALPINE_BASE}
ARG UPDATER_VERSION=dev
LABEL org.opencontainers.image.title="unbound-autoupdate" \
      org.opencontainers.image.description="Canary-tested automatic updater and Prometheus exporter for unbound-distroless" \
      org.opencontainers.image.source="https://github.com/ESITC-Paris/unbound-distroless" \
      org.opencontainers.image.version="${UPDATER_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="ESITC Paris"

# The base is digest-pinned so the *base* is reproducible; `apk upgrade` then
# applies the security updates Alpine published after that digest was cut, in
# the same layer as the install. Without it the image ships whatever CVEs the
# pinned base carried at pin time, which the Trivy OS gate refuses. Rebuilds
# are still triggered by the monitor's digest tracking (upstream-check.yml),
# so the pin keeps moving forward rather than drifting silently.
# bash: arrays and `local -n` are used throughout. util-linux: flock.
# tini: loop mode must forward SIGTERM so `docker compose down` is prompt.
# busybox-extras: httpd (the /metrics endpoint) and nc.
RUN apk upgrade --no-cache \
 && apk add --no-cache \
      bash docker-cli docker-cli-compose bind-tools curl ca-certificates \
      coreutils util-linux tini jq busybox-extras

# cosign v3 CLI (the image is distroless; /ko-app/cosign is its binary). v3
# verifies signatures produced by cosign v2, which is what release.yml still
# signs with — see updater/README.md.
COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign

COPY lib/ /usr/local/lib/unbound-autoupdate/
COPY www/ /usr/local/lib/unbound-autoupdate/www/
COPY unbound-autoupdate entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/unbound-autoupdate /usr/local/bin/entrypoint.sh \
      /usr/local/lib/unbound-autoupdate/www/cgi-bin/metrics \
 && printf '%s\n' "$UPDATER_VERSION" > /usr/local/lib/unbound-autoupdate/VERSION

EXPOSE 9167

# The container runs as root on purpose: it needs the Docker socket, which is
# root-equivalent anyway. Documented in updater/README.md rather than hidden.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
