# unbound-distroless

[![CI](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/ci.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/ci.yml)
[![Release](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/release.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/release.yml)
[![Upstream check](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml/badge.svg)](https://github.com/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml)
[![Docker Hub](https://img.shields.io/docker/v/esitcparis/unbound-distroless?sort=semver&label=docker%20hub)](https://hub.docker.com/r/esitcparis/unbound-distroless)

The [Unbound](https://nlnetlabs.nl/projects/unbound/) DNS resolver, built from
the NLnet Labs source release, on a distroless base: no shell, no package
manager, runs as UID 65532, validates DNSSEC. Images for `linux/amd64` and
`linux/arm64`, signed with cosign, with SBOM and provenance, rebuilt
automatically when Unbound or a base image changes or when a published image
has a fixable vulnerability.

Maintained by the IT department of ESITC Paris. Support is best effort, with no SLA: questions and bugs go to
[issues](https://github.com/ESITC-Paris/unbound-distroless/issues),
vulnerabilities to [private reporting](SECURITY.md). This is not an official
NLnet Labs project.

## Try it

No preparation, nothing on port 53: the resolver listens on `127.0.0.1:5053`
only. `dig` comes with `dnsutils` / `bind9-dnsutils` (or `bind` on macOS).

<!-- quickstart:try — tests/quickstart.sh runs this block as written -->
```bash
docker run -d --rm --name unbound-try -p 127.0.0.1:5053:53/udp -p 127.0.0.1:5053:53/tcp esitcparis/unbound-distroless:latest
dig @127.0.0.1 -p 5053 example.com +dnssec   # status: NOERROR, and "ad" in the flags: validated
dig @127.0.0.1 -p 5053 dnssec-failed.org     # status: SERVFAIL: a broken signature is refused
docker stop unbound-try
```

If the first `dig` times out, the resolver is still starting: run it again.

## Run it

A resolver on port 53 of the host, hardened (all capabilities dropped except
`NET_BIND_SERVICE`, `no-new-privileges`, read-only root filesystem), with its
DNSSEC state on a named volume:

<!-- quickstart:run — tests/quickstart.sh runs this block as written -->
```bash
mkdir unbound && cd unbound
curl -fsSLO https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/docker-compose.yml
docker compose up -d
dig @127.0.0.1 example.com +dnssec   # status: NOERROR, and "ad" in the flags
dig @127.0.0.1 dnssec-failed.org     # status: SERVFAIL
```

**Port 53 already in use?** If `docker compose up -d` fails with `address
already in use`, something on the host already listens on port 53 — on
Ubuntu and other systemd distributions usually the `systemd-resolved` stub on
`127.0.0.53`. Either publish on one address of the host instead of all of
them, by changing the two `ports:` lines of `docker-compose.yml` to, for
example, `"192.0.2.10:53:53/udp"` and `"192.0.2.10:53:53/tcp"` (your LAN
address); or turn the stub off (`DNSStubListener=no` in
`/etc/systemd/resolved.conf`, then restart `systemd-resolved`) and point the
host's `/etc/resolv.conf` at a resolver that still exists.

The default configuration answers clients from loopback and private ranges
(RFC 1918, IPv6 ULA and link-local) and refuses everyone else.

**Production:** pin the image. In `docker-compose.yml`, replace
`esitcparis/unbound-distroless:1` with an `X.Y.Z-rN` tag or an `@sha256:`
digest from the [releases page](https://github.com/ESITC-Paris/unbound-distroless/releases)
— or keep `:1` and let the [update sidecar](updater/README.md) move it for
you, after a canary with your configuration. Without the sidecar, see
[Updating without the sidecar](docs/usage.md#updating-without-the-sidecar).

## Configuration

```bash
curl -fsSLO https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/unbound.conf
# edit it, then validate it with the image that will run it:
docker run --rm -v "$PWD/unbound.conf:/etc/unbound/unbound.conf:ro" \
  --entrypoint /usr/local/sbin/unbound-checkconf \
  esitcparis/unbound-distroless:1 /etc/unbound/unbound.conf
```

Then uncomment the `./unbound.conf` line in `docker-compose.yml` and run
`docker compose up -d --force-recreate`. The shipped
[`unbound.conf`](unbound.conf) is annotated and has commented examples for
everything below; [docs/usage.md](docs/usage.md) covers the rest.

## What is built in, and what is not

Built in, off until configured: DNS over TLS and DNS over HTTPS serving
(OpenSSL, nghttp2), a shared cache in Redis or Valkey (`cachedb`, hiredis),
EDNS Client Subnet (`subnetcache`), dnstap logging.

On by default: recursion with DNSSEC validation, the root trust anchor
tracked by RFC 5011, a local copy of the root zone (RFC 8806) kept current by
zone transfer, serve-expired, prefetch, QNAME minimisation.

Not built in: DNS over QUIC (Debian 13 packages ngtcp2 only with its GnuTLS
helper, Unbound needs the OpenSSL one), the Python and dynamic-library
modules, a shell, a package manager. The licences of everything in the image
are listed in [NOTICE](NOTICE); NOTICE, the licence texts and every
package's copyright file are shipped under `/usr/share/doc`.

## Tags

`esitcparis/unbound-distroless` (Docker Hub) and
`ghcr.io/esitc-paris/unbound-distroless` carry the same images, with the same
digests.

| Tag | Meaning |
|---|---|
| `X.Y.Z-rN` | One build: Unbound `X.Y.Z`, image revision `N`. Published once, never re-pushed. Pin this or a digest in production. |
| `X.Y.Z`, `X.Y`, `X`, `latest` | Move to each new build of the current line. |

The revision `N` increases when the same Unbound version is rebuilt: a base
image update, a fixable vulnerability found in the published image, or a
rebuild requested by the maintainer. Current versions and their digests are on the
[releases page](https://github.com/ESITC-Paris/unbound-distroless/releases)
(Watch → Custom → Releases to be notified).

## Support policy

Only the current line is maintained: the build behind `latest`. When Unbound
releases a new version, the tags of the previous one (`X.Y.Z`, and `X.Y` once
the minor version changes) stop moving and receive no further fixes. Move to
the newest release to stay patched.

## What you are trusting

The source tarball is checked against NLnet Labs' OpenPGP signature before
its hash is recorded; the build refuses any other bytes. Every release is
built and tested natively on both architectures, blocked by Trivy on any
fixable CRITICAL or HIGH vulnerability, and signed by this repository's
GitHub Actions release workflow — which you can check with one `cosign`
command. Beyond that you are trusting GitHub Actions, the Debian and
distroless base images, the registries, and one maintainer. Details and
verification commands: [docs/trust.md](docs/trust.md).

## Documentation

- [docs/usage.md](docs/usage.md) — `docker run` recipes, port 53 and
  capabilities, health checks, Kubernetes, configuration, tuning,
  troubleshooting, local build, updating without the sidecar
- [docs/production.md](docs/production.md) — a two-host reference deployment
  with the update sidecar, Prometheus alerts and runbooks
- [updater/README.md](updater/README.md) — the update sidecar
  (`esitcparis/unbound-autoupdate`): canary, swap, rollback, `/metrics`; it
  needs the Docker socket, read this first
- [docs/trust.md](docs/trust.md) — release gates, how to verify an image,
  vulnerability handling, DNSSEC and root data
- [docs/operations.md](docs/operations.md) — for maintainers: how the
  automation is triggered and supervised, release recovery, repository
  settings
- [SECURITY.md](SECURITY.md) — reporting a vulnerability
- [CONTRIBUTING.md](CONTRIBUTING.md) — building and testing locally

## License

The repository is [MIT](LICENSE). Unbound is BSD-3-Clause, by
[NLnet Labs](https://nlnetlabs.nl/); third-party notices are in
[NOTICE](NOTICE).
