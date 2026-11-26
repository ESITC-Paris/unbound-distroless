# unbound-distroless

[![CI](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/ci.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/ci.yml)
[![Release](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/release.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/release.yml)
[![Upstream check](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml)
[![Docker Hub](https://img.shields.io/docker/v/esitcparis/unbound-distroless?sort=semver&label=docker%20hub)](https://hub.docker.com/r/esitcparis/unbound-distroless)

The [Unbound](https://nlnetlabs.nl/projects/unbound/) DNS resolver on a
distroless base: no shell, no package manager, runs as UID 65532, validates
DNSSEC. Built from the NLnet Labs source release for `linux/amd64` and
`linux/arm64`, signed with cosign, and rebuilt automatically when Unbound or
a base image changes or when a published image has a fixable vulnerability.

## Run it

Save one of the two files below as `docker-compose.yml`, then start it:

<!-- quickstart:run — tests/quickstart.sh runs this block as written -->
```bash
docker compose up -d
dig @127.0.0.1 example.com +dnssec   # status: NOERROR, and "ad" in the flags: validated
dig @127.0.0.1 dnssec-failed.org     # status: SERVFAIL: a broken signature is refused
```

The resolver listens on `127.0.0.1:53`: it serves this host and nothing else
until you [give it an address of your network](#serving-your-network). If the
first `dig` times out, the resolver is still starting: run it again.

### Resolver only

You update it yourself
([how](docs/usage.md#updating-without-the-sidecar)). In production, replace
`:1` with an `X.Y.Z-rN` tag from the
[releases page](https://github.com/ESITC-Paris/unbound-distroless/releases).

<!-- quickstart:compose — tests/quickstart.sh checks this block against docker-compose.yml -->
```yaml
services:
  unbound:
    image: esitcparis/unbound-distroless:1
    container_name: unbound
    restart: unless-stopped
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs:
      - "/run/unbound:uid=65532,gid=65532"
    ports:
      - "127.0.0.1:53:53/udp"   # this host only: see "Serving your network"
      - "127.0.0.1:53:53/tcp"
    volumes:
      - unbound-data:/var/lib/unbound
      # - ./unbound.conf:/etc/unbound/unbound.conf:ro   # your own configuration
    ulimits:
      nofile: { soft: 16384, hard: 16384 }

volumes:
  unbound-data:
```

### Resolver with automatic updates

The same resolver, plus the [update sidecar](updater/README.md): every hour it
looks for a new image, verifies its signature, tries it with your
configuration on a copy of the resolver's state, swaps it in and rolls back
if the new resolver does not answer. A second container serves Prometheus
metrics on `127.0.0.1:9167`.

<!-- quickstart:compose-sidecar — tests/sidecar-docs.sh checks this block against docker-compose.yml + updater/compose.snippet.yml -->
```yaml
services:
  unbound:
    image: esitcparis/unbound-distroless:1
    container_name: unbound
    restart: unless-stopped
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs:
      - "/run/unbound:uid=65532,gid=65532"
    ports:
      - "127.0.0.1:53:53/udp"   # this host only: see "Serving your network"
      - "127.0.0.1:53:53/tcp"
    volumes:
      - unbound-data:/var/lib/unbound
      # - ./unbound.conf:/etc/unbound/unbound.conf:ro   # your own configuration
    ulimits:
      nofile: { soft: 16384, hard: 16384 }

  unbound-autoupdate:
    image: esitcparis/unbound-autoupdate:1
    restart: unless-stopped
    stop_grace_period: 2m
    environment:
      INTERVAL: 1h
      METRICS_COLLECT_INTERVAL: 30s   # statistics for unbound-metrics, which has no Docker socket
      # HC_URL: https://hc-ping.com/<uuid>   # be alerted when an update fails
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/unbound:/opt/unbound:ro   # the directory of this file, same path on both sides
      - autoupdate-state:/var/lib/unbound-autoupdate

  unbound-metrics:
    image: esitcparis/unbound-autoupdate:1
    command: ["metrics"]
    restart: unless-stopped
    # No Docker socket here: it serves what unbound-autoupdate collects.
    user: "65534:65534"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs: [/tmp]
    ports:
      - "127.0.0.1:9167:9167"
    volumes:
      - autoupdate-state:/var/lib/unbound-autoupdate:ro

volumes:
  unbound-data:
  autoupdate-state:
```

Three things to know before you start it:

- **The file must be in `/opt/unbound`**, or change both sides of the
  `/opt/unbound:/opt/unbound:ro` line to the directory it is in.
- **Docker Compose 5 or later on the host** (`docker compose version`), 5.5.0
  or later on the containerd image store. With an older Compose the updates
  still happen, but your next `docker compose up -d` restarts the resolver
  ([why](updater/README.md#what-a-cycle-does)).
- **The sidecar mounts the Docker socket, which is root on the host.** What it
  does with it: [updater/README.md](updater/README.md#the-docker-socket-is-root-on-the-host).

### Serving your network

To answer other machines, replace `127.0.0.1` in the two `ports:` lines with
the address of the host on the network to serve, for example
`"192.0.2.10:53:53/udp"` and `"192.0.2.10:53:53/tcp"`, then
`docker compose up -d`.

Name an address; do not publish on all of them (`"53:53/udp"`). The shipped
configuration answers loopback and private ranges only (RFC 1918, IPv6 ULA
and link-local), but behind Docker's port publishing a client from anywhere
can reach Unbound with the address of the Docker bridge, which is in those
ranges ([usage.md](docs/usage.md#docker-run)): on a host with a public
address, `"53:53"` is an open resolver, usable to amplify attacks on others.

### Port 53 already in use?

If `docker compose up -d` fails with `address already in use`, something on
the host already listens on that address and port. Publishing on one address
avoids the usual case, the `systemd-resolved` stub of Ubuntu and other
systemd distributions, which listens on `127.0.0.53` and not on `127.0.0.1`
or your LAN address. For anything else, `ss -lntup 'sport = :53'` shows what
listens.

## Try it

One command, nothing installed, nothing on port 53: the resolver listens on
`127.0.0.1:5053` only.

<!-- quickstart:try — tests/quickstart.sh runs this block as written -->
```bash
docker run -d --rm --name unbound-try -p 127.0.0.1:5053:53/udp -p 127.0.0.1:5053:53/tcp esitcparis/unbound-distroless:latest
dig @127.0.0.1 -p 5053 example.com +dnssec   # status: NOERROR, and "ad" in the flags
dig @127.0.0.1 -p 5053 dnssec-failed.org     # status: SERVFAIL
docker stop unbound-try
```

## Configuration

The image runs with a complete default configuration. To change it, fetch the
annotated file, edit it, and validate it with the image that will run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/unbound.conf
docker run --rm -v "$PWD/unbound.conf:/etc/unbound/unbound.conf:ro" \
  --entrypoint /usr/local/sbin/unbound-checkconf \
  esitcparis/unbound-distroless:1 /etc/unbound/unbound.conf
```

Then uncomment the `./unbound.conf` line in `docker-compose.yml` and run
`docker compose up -d --force-recreate`. [docs/usage.md](docs/usage.md)
covers the rest.

## What is in the image

- **On by default:** recursion with DNSSEC validation, the root trust anchor
  tracked by RFC 5011, a local copy of the root zone (RFC 8806) kept current
  by zone transfer, serve-expired, prefetch, QNAME minimisation.
- **Built in, off until configured:** DNS over TLS and DNS over HTTPS serving,
  a shared cache in Redis or Valkey (`cachedb`), EDNS Client Subnet
  (`subnetcache`), dnstap logging.
- **Not built in:** DNS over QUIC (Debian 13 packages ngtcp2 only with its
  GnuTLS helper, Unbound needs the OpenSSL one), the Python and
  dynamic-library modules, a shell, a package manager.

The licences of everything in the image are listed in [NOTICE](NOTICE) and
shipped under `/usr/share/doc`.

## Tags

`esitcparis/unbound-distroless` (Docker Hub) and
`ghcr.io/esitc-paris/unbound-distroless` carry the same images, with the same
digests.

| Tag | Meaning |
|---|---|
| `X.Y.Z-rN` | One build: Unbound `X.Y.Z`, image revision `N`. Published once, never re-pushed. Pin this or a digest in production. |
| `X.Y.Z`, `X.Y`, `X`, `latest` | Move to each new build of the current line. |

The revision `N` increases when the same Unbound version is rebuilt: a base
image update, a fixable vulnerability in the published image, or a rebuild
requested by the maintainer. Versions and digests are on the
[releases page](https://github.com/ESITC-Paris/unbound-distroless/releases)
(Watch → Custom → Releases to be notified).

Only the current line is maintained: when Unbound releases a new version, the
tags of the previous one stop moving and receive no further fixes.

## What you are trusting

The source tarball is checked against NLnet Labs' OpenPGP signature. Every
release is built and tested natively on both architectures, blocked by Trivy
on any fixable CRITICAL or HIGH vulnerability, and signed by this
repository's release workflow, which you can check with one `cosign` command.
Beyond that you are trusting GitHub Actions, the Debian and distroless base
images, the registries, and one maintainer. Details and verification
commands: [docs/trust.md](docs/trust.md).

## Documentation

- [docs/usage.md](docs/usage.md) — `docker run` recipes, port 53 and
  capabilities, health checks, Kubernetes, configuration, tuning,
  troubleshooting, local build, updating without the sidecar
- [updater/README.md](updater/README.md) — the update sidecar
  (`esitcparis/unbound-autoupdate`): canary, swap, rollback, `/metrics`
- [docs/production.md](docs/production.md) — a two-host reference deployment
  with the update sidecar, Prometheus alerts and runbooks
- [docs/trust.md](docs/trust.md) — release gates, how to verify an image,
  vulnerability handling, DNSSEC and root data
- [docs/operations.md](docs/operations.md) — for maintainers: how the
  automation is triggered and supervised, release recovery, repository
  settings
- [SECURITY.md](SECURITY.md) — reporting a vulnerability
- [CONTRIBUTING.md](CONTRIBUTING.md) — building and testing locally

## Support and license

Maintained by the IT department of ESITC Paris, best effort, with no SLA.
Questions and bugs go to
[issues](https://github.com/ESITC-Paris/unbound-distroless/issues),
vulnerabilities to [private reporting](SECURITY.md). This is not an official
NLnet Labs project.

The repository is [MIT](LICENSE). Unbound is BSD-3-Clause, by
[NLnet Labs](https://nlnetlabs.nl/); third-party notices are in
[NOTICE](NOTICE).
