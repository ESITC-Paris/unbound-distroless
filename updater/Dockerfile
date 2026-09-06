# syntax=docker/dockerfile:1

# Digests resolved in Step 1 — replace both placeholders with the real values.
ARG ALPINE_BASE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5@sha256:ad281047f85c5e1fc6ffbc30c2b55be3b07b4032bef715a12122ce5829619aca

FROM ${COSIGN_IMAGE} AS cosign

FROM ${ALPINE_BASE}
ARG UPDATER_VERSION=dev
LABEL org.opencontainers.image.title="unbound-autoupdate" \
      org.opencontainers.image.description="Canary-tested automatic updater for unbound-distroless" \
      org.opencontainers.image.source="https://github.com/ESITC-Paris/unbound-distroless" \
      org.opencontainers.image.version="${UPDATER_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="ESITC Paris"

# bash: arrays and `local -n` are used throughout. util-linux: flock.
# tini: the loop mode must forward SIGTERM so `docker compose down` is prompt.
RUN apk add --no-cache \
      bash docker-cli docker-cli-compose bind-tools curl ca-certificates \
      coreutils util-linux tini jq

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign

COPY lib/ /usr/local/lib/unbound-autoupdate/
COPY unbound-autoupdate entrypoint.sh /usr/local/bin/
COPY VERSION /usr/local/lib/unbound-autoupdate/VERSION
RUN chmod 0755 /usr/local/bin/unbound-autoupdate /usr/local/bin/entrypoint.sh

# The container runs as root on purpose: it needs the Docker socket, which is
# root-equivalent anyway. Documented in updater/README.md rather than hidden.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
