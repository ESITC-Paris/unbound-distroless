# Security Policy

## Reporting a vulnerability

For issues in this packaging (Dockerfile, configuration, pipeline), open a
[GitHub security advisory](https://github.com/ESITC-Paris/unbound-distroless/security/advisories/new).

For vulnerabilities in Unbound itself, report to NLnet Labs at
<security@nlnetlabs.nl>; see their
[security advisories](https://nlnetlabs.nl/projects/unbound/security-advisories/)
page for published issues.

## Supply-chain measures

- Source tarballs are verified against a pinned SHA-256 before building.
- Images are built on GitHub Actions, signed with cosign (keyless, GitHub
  OIDC), and published with SBOM + SLSA provenance attestations.
- Every release is gated on a functional test suite and a Trivy scan
  (CRITICAL/HIGH, unfixed excluded).
- A daily job rebuilds the image whenever the Debian build stage or the
  distroless runtime base publishes an update, so runtime libraries
  (glibc, OpenSSL, libevent, expat) never lag upstream fixes for long.
- Harvested runtime libraries carry their dpkg metadata in
  `/var/lib/dpkg/status.d/`, so scanners (Trivy, Grype, Scout) can identify
  their exact package versions.

## Verifying an image

See "Verifying releases" in the README for cosign and attestation commands.
Always pin deployments to an immutable `X.Y.Z-rN` tag or a digest.
