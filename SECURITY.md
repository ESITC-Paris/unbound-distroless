# Security policy

## Reporting a vulnerability

Report privately through GitHub:
[Report a vulnerability](https://github.com/ESITC-Paris/unbound-distroless/security/advisories/new)
(Security tab → Report a vulnerability). Do not open a public issue.

The repository is maintained by the IT department of ESITC Paris on a
best-effort basis, with no SLA. You will get an answer in the advisory
thread; a fix ships as a new image revision through the normal release
pipeline.

## Scope

In scope: what this repository builds and publishes.

- the resolver image `esitcparis/unbound-distroless` /
  `ghcr.io/esitc-paris/unbound-distroless`: the `Dockerfile`, the shipped
  `unbound.conf`, how libraries are selected and copied;
- the update sidecar `esitcparis/unbound-autoupdate` /
  `ghcr.io/esitc-paris/unbound-autoupdate` (`updater/`);
- the release and update workflows (`.github/`), the trigger script
  (`deploy/`), and anything that could let someone publish or sign an image
  outside them.

Not in scope here:

- **Unbound itself**: report to NLnet Labs (<security@nlnetlabs.nl>); their
  [security advisories](https://nlnetlabs.nl/projects/unbound/security-advisories/)
  list published issues.
- **A known CVE in a Debian or Alpine package** of a published image, once
  the distribution has a fix: the update monitor rescans the published images
  and rebuilds them on its own ([docs/trust.md](docs/trust.md#vulnerabilities-after-release)).
  If a published image still carries such a fix-available CVE after that,
  open an ordinary issue.
- **HIGH findings in the sidecar's vendored `cosign` binary**: known and
  gated at CRITICAL only, for the reason given in
  [docs/trust.md](docs/trust.md#from-source-to-registry).

## Supported versions

Only the current line is supported: the resolver and sidecar images behind
`latest`. They are rebuilt when Unbound or a base image changes and when the
rescan finds a fixable vulnerability. When Unbound releases a new version, the
tags of the previous one (`X.Y.Z`, and `X.Y` or `X` once the minor or major
version changes) stop moving and get no further fixes; every `X.Y.Z-rN` tag
is a fixed build that is never updated. Stay on the newest release, by tag or
with the [update sidecar](updater/README.md).

How images are built, signed and verified: [docs/trust.md](docs/trust.md).
