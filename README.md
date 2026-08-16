# unbound-distroless

[![CI](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/ci.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/ci.yml)
[![Release](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/release.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/release.yml)
[![Upstream check](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml)
[![Docker Hub](https://img.shields.io/docker/v/esitcparis/unbound-distroless?sort=semver&label=docker%20hub)](https://hub.docker.com/r/esitcparis/unbound-distroless)

A production-grade [Unbound](https://nlnetlabs.nl/projects/unbound/) DNS
resolver on a distroless base.

*This is a community-maintained image. It is not an official NLnet Labs
project.*

## Quick start (Docker Compose)

Create a `docker-compose.yml`:

```yaml
services:
  unbound:
    image: esitcparis/unbound-distroless:latest
    container_name: unbound
    restart: unless-stopped
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    ports:
      - "53:53/udp"
      - "53:53/tcp"
    volumes:
      # Persists the auto-updating DNSSEC trust anchor and root zone copy.
      - unbound-data:/var/lib/unbound
      # Your own configuration (see below) — uncomment once created:
      # - ./unbound.conf:/etc/unbound/unbound.conf:ro

volumes:
  unbound-data:
```

```bash
docker compose up -d
dig @127.0.0.1 example.com          # NOERROR
dig @127.0.0.1 . SOA +dnssec        # 'ad' flag = DNSSEC validation active
```

## Use your own configuration

```bash
# 1. Start from the shipped default
curl -fsSL -o unbound.conf \
  https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/unbound.conf

# 2. Edit it, then validate it
docker run --rm -v "$PWD/unbound.conf:/etc/unbound/unbound.conf:ro" \
  --entrypoint /usr/local/sbin/unbound-checkconf \
  esitcparis/unbound-distroless:latest /etc/unbound/unbound.conf

# 3. Uncomment the config line in docker-compose.yml, then
docker compose up -d --force-recreate
```

## Images and tags

`esitcparis/unbound-distroless` (Docker Hub) · `ghcr.io/esitc-paris/unbound-distroless` — `linux/amd64` + `linux/arm64`.

Tags follow the pattern `X.Y.Z-rN`, where `X.Y.Z` is the Unbound version and
`rN` is the image revision (incremented when the same Unbound version is
rebuilt for base-image or library updates).

| Tag pattern | Meaning |
|---|---|
| `X.Y.Z-rN` | Exact build — **immutable, pin this in production** |
| `X.Y.Z`, `X.Y`, `X`, `latest` | Mutable, track the newest rebuild |

Current versions are listed on the
[releases page](https://github.com/ESITC-Paris/unbound-distroless/releases).

## Learn more

- **[Usage guide](docs/usage.md)** — `docker run` recipes (localhost-only,
  read-only rootfs), Kubernetes, DoT/DoH serving, Valkey/Redis shared cache,
  tuning, health checks, troubleshooting
- **[Trust & automation](docs/trust.md)** — the release gates (GPG-verified
  source, dual-arch native tests, CVE scan, cosign signing, SBOM/SLSA),
  hourly automatic updates, how to verify an image, DNSSEC key & root zone
  lifecycle
- **[SECURITY.md](SECURITY.md)** — vulnerability reporting
- **[Releases](https://github.com/ESITC-Paris/unbound-distroless/releases)** —
  per-version digests and notes (Watch → Custom → Releases to get notified)

## License

Repository: [MIT](LICENSE). Unbound is BSD-3-Clause by
[NLnet Labs](https://nlnetlabs.nl/).
