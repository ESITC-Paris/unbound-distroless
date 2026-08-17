# Trust & automation

How this image is built, tested, published, and kept current — and how you
can verify all of it yourself.

## Why you can trust this image

Every release — including the fully automatic ones — must pass this pipeline
before a single tag is published. There are no manual builds and no shortcuts:
the pipeline is the only path to the registries.

| # | Gate | What it guarantees |
|---|------|--------------------|
| 1 | **GPG signature verification** | The Unbound source tarball is verified against NLnet Labs' release signing key (fingerprint pinned in the repo) *before* its checksum is ever recorded. A bad signature blocks everything. |
| 2 | **SHA-256 pinned source** | The build refuses any tarball whose checksum differs from the committed pin. |
| 3 | **Digest-pinned bases** | `debian:trixie` (build) and `distroless/base-debian13` (runtime) are consumed by digest, so the image that was tested is bit-for-bit the image that is published. |
| 4 | **Native builds, both architectures** | amd64 and arm64 are each built **and fully tested on native runners** — no QEMU emulation anywhere. |
| 5 | **Functional test suite (per arch)** | The container is started with the documented hardening flags and must: reach `healthy`, resolve real domains over UDP and TCP, prove DNSSEC validation (AD flag; a deliberately-broken domain must SERVFAIL), serve cache hits, load the hyperlocal root zone, expose the DoH/cachedb capabilities, and answer `unbound-control` over its Unix socket. |
| 6 | **Structure test suite (per arch)** | Asserts the security invariants: runs as UID 65532, **no shell**, no package manager, no baked-in private keys, expected files only. |
| 7 | **CVE scan gate (per arch)** | Trivy blocks the release on any fixable CRITICAL/HIGH vulnerability. |
| 8 | **Untagged until proven** | Platform images are pushed *by digest only*; the public tags appear in one final step after every gate above has passed on both architectures. |
| 9 | **Signing & attestations** | The published multi-arch index is signed with **cosign keyless** (GitHub OIDC — the signing identity *is* this repository's workflow) and carries **SBOM + SLSA provenance** attestations. |

Additional supply-chain hygiene: every GitHub Action in the pipelines is
pinned to a full commit SHA, workflow shells never interpolate untrusted
input, release tags are format-validated before anything runs, and each
[GitHub Release](https://github.com/ESITC-Paris/unbound-distroless/releases)
records the exact image digests with a ready-to-run verification command.

## Automatic updates

An update check runs **every hour** (triggered from ESITC-operated
infrastructure — see [operations.md](operations.md)) and looks for:

1. **New Unbound releases** (NLnet Labs) → new `X.Y.Z-r0` release
2. **Updated base images** — the Debian build stage or the distroless runtime
   base → revision rebuild `X.Y.Z-rN`, which picks up OpenSSL, glibc,
   libevent, nghttp2, hiredis, and expat security fixes

Detection to publication is fully automatic; the gate table above is the
safety net. A failed gate publishes nothing and leaves a red run in
[Actions](https://github.com/ESITC-Paris/unbound-distroless/actions) for
human eyes. To be notified of new releases: **Watch → Custom → Releases**
on the repository.

**Version scheme:** image `X.Y.Z-rN` = Unbound version `X.Y.Z`, rebuild
revision `N`. The revision increments when the same Unbound version is
rebuilt (base/library updates or image improvements); `-rN` tags are
immutable, `X.Y.Z`/`X.Y`/`X`/`latest` are mutable pointers to the newest
build.

## Verifying releases

Images are signed with [cosign](https://docs.sigstore.dev/) keyless signing —
the signing identity is this repository's release workflow, so a valid
signature proves the image came out of the pipeline described above:

```bash
cosign verify esitcparis/unbound-distroless:latest \
  --certificate-identity-regexp 'https://github.com/ESITC-Paris/unbound-distroless/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Inspect the SBOM and SLSA provenance attestations:

```bash
docker buildx imagetools inspect esitcparis/unbound-distroless:latest \
  --format '{{ json .SBOM }}'
docker buildx imagetools inspect esitcparis/unbound-distroless:latest \
  --format '{{ json .Provenance }}'
```

Every [GitHub Release](https://github.com/ESITC-Paris/unbound-distroless/releases)
lists the exact digests. Pin production deployments to an immutable
`X.Y.Z-rN` tag or a digest.

## DNSSEC trust anchor and root data lifecycle

All three data files are managed automatically; the volume
(`/var/lib/unbound`) is what makes the runtime state survive restarts.

**Trust anchor (`/var/lib/unbound/root.key`)**
- Generated **fresh at every image build** by `unbound-anchor` (never a stale
  checked-in file).
- At runtime, Unbound performs **RFC 5011 automatic trust-anchor tracking**:
  it probes the root key and rewrites the file itself (verified behavior —
  the file is rewritten with a new probe timestamp at startup and on the
  RFC 5011 schedule thereafter).
- With the volume, the tracked anchor **persists across restarts, upgrades,
  and container recreation** — this is what keeps you safe across a root KSK
  rollover. Docker seeds a named volume from the image only when the volume
  is empty; afterwards the RFC 5011 updates keep it current.

**Hyperlocal root zone (`/var/lib/unbound/root.zone`) — [RFC 8806](https://www.rfc-editor.org/rfc/rfc8806)**
- The full root zone is **baked at every image build**, so the resolver
  starts warm: lookups skip the round-trip to root servers and non-existent
  TLDs get an instant local NXDOMAIN.
- At runtime, **Unbound keeps the copy fresh itself** via AXFR/IXFR from the
  root servers, following the zone's SOA timers, and persists it in the
  volume alongside the trust anchor.
- Fail-safe by construction: every answer still passes DNSSEC validation,
  and `fallback-enabled: yes` means normal recursion transparently takes
  over if the local copy is stale or a transfer fails.
- Verify live: `unbound-control list_auth_zones` shows the zone and serial.

**Root hints (`/etc/unbound/root.hints`)**
- Downloaded from InterNIC **at every image build** — and images are rebuilt
  automatically on every upstream or base update, so hints stay current
  without runtime writes. Unbound only needs them to find *one* root server;
  priming self-corrects stale entries.
