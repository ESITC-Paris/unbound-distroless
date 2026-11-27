# Trust and verification

How an image gets from the Unbound source release to a registry, what has to
pass on the way, how to check a published image yourself, and how
vulnerabilities and DNS root data are handled afterwards. Each statement names
the workflow or test that enforces it.

## From source to registry

Releases are produced only by two GitHub Actions workflows, started by an
explicit dispatch on a release tag: [`release.yml`](../.github/workflows/release.yml)
for the resolver (tags `vX.Y.Z-rN`) and
[`updater.yml`](../.github/workflows/updater.yml) for the update sidecar
(tags `updater-vX.Y.Z-rN`). The release tags are created by the update monitor,
[`upstream-check.yml`](../.github/workflows/upstream-check.yml); how it is
started and supervised is in [operations.md](operations.md).

| # | Step | What it guarantees |
|---|---|---|
| 1 | **OpenPGP-verified source** | When the monitor pins a new Unbound version, it downloads the tarball and its `.asc`, imports the NLnet Labs signing key vendored at [`.github/keys/`](../.github/keys/), refuses it unless its fingerprint is the one pinned in the workflow, runs `gpg --verify`, and checks NLnet Labs' published `.sha256`. Only then does it record the tarball's SHA-256 in `versions.env`. The steps to redo this by hand are in the [`Dockerfile`](../Dockerfile), above the download. |
| 2 | **Hash-pinned source** | The build refuses any tarball whose SHA-256 differs from `versions.env`. |
| 2b | **Compiler hardening** | Unbound is compiled with Debian's own hardening flags for the release and the architecture (`dpkg-buildflags`, `hardening=+all`): stack protector, stack clash protection, `_FORTIFY_SOURCE`, control-flow protection (CET on amd64, BTI and pointer authentication on arm64), position-independent executables, full RELRO. The build stops if the binaries or `libunbound` do not carry them, and the structure suite checks the shipped files again. |
| 3 | **Digest-pinned bases, current packages** | `debian:trixie` (build stage) and `gcr.io/distroless/base-debian13` (runtime) are used by the digests recorded in `.build-state.json`. The build stage runs `apt-get upgrade`, and the runtime libraries are copied from that stage with their dpkg metadata, so an image carries the Debian security updates published up to its build. The package-upgrade layer depends on the image revision, so each new revision re-runs it instead of reusing a cached layer. |
| 4 | **Release matches the tree** | The workflow must run on the tag it publishes, and the tag must match the version and revision in `versions.env` at that tag. |
| 5 | **Published once, never backwards** | A release never pushes an `X.Y.Z-rN` image tag that already exists on Docker Hub or GHCR, and stops when a registry cannot answer. A run dispatched again on a published tag only finishes the remaining publication steps, and only for an image already signed by that tag's run and for the revision `main` holds now. A tag that was never published is built only if it is that revision: an old tag dispatched by hand or by mistake cannot move `latest` back to an old build ([`release-mode.sh`](../.github/scripts/release-mode.sh), [`refuse-published.sh`](../.github/scripts/refuse-published.sh)). |
| 6 | **Native builds and tests, both architectures** | amd64 and arm64 are each built and tested on a runner of that architecture, without emulation. |
| 7 | **Functional suite** ([`tests/functional.sh`](../tests/functional.sh)) | The container, started with `--cap-drop=ALL --cap-add=NET_BIND_SERVICE --security-opt no-new-privileges`, must become `healthy`; resolve over UDP and TCP; return the `ad` flag on the root SOA; SERVFAIL on `dnssec-failed.org` and answer it with `+cd`; answer a repeated query from cache in under 100 ms; answer `unbound-control` on its socket; load the local root zone; be built with nghttp2, cachedb, hiredis, subnet and dnstap, and without the Python and dynamic-library modules; keep the subnet and dnstap features off with the shipped configuration and start them when configured; log no unexpected error; and pass the [port 53 cases](usage.md#port-53-and-capabilities) ([`tests/port53.sh`](../tests/port53.sh)). |
| 8 | **Structure suite** ([`tests/structure.sh`](../tests/structure.sh)) | Unbound's binaries and `libunbound` carry the compiler hardening of step 2b; the image's user resolves to UID and GID 65532 in its own `/etc/passwd` and owns the two writable directories; the only executables on any `bin` or `sbin` directory are Unbound's five binaries, each an ELF file that runs in the image; no shell or package manager by name anywhere in the file system; no private key in any file; every Debian package recorded in `/var/lib/dpkg/status.d` has its copyright file; Unbound's LICENSE and this repository's LICENSE and NOTICE are present. |
| 9 | **Vulnerability gate** | Trivy fails the release on any CRITICAL or HIGH vulnerability that has a fix, on each architecture. |
| 10 | **Untagged until signed** | Each architecture pushes its image by digest only. The multi-arch index is then created under the immutable `X.Y.Z-rN` tag only, must have the same digest on both registries, is signed with cosign (keyless, GitHub OIDC), verified with the commands published below and in the release notes, and attested. Only then do `latest`, `X`, `X.Y` and `X.Y.Z` move to that digest, after a check that the index the move would push (`imagetools create --dry-run`) has exactly the signed digest; each tag is then read back from both registries. |
| 11 | **Attestations** | The image index carries an SPDX SBOM and BuildKit SLSA provenance (`mode=max`) on both registries. A GitHub build-provenance attestation for the index digest is stored in GitHub's attestation store, for both image names; it is not pushed to the registries. |

Every action in the workflows is pinned to a full commit SHA, workflow
`run:` steps never expand `${{ }}` expressions inline, and each
[GitHub Release](https://github.com/ESITC-Paris/unbound-distroless/releases)
lists the index digest and a verify command for that exact build.

**The sidecar's gates differ.** `updater.yml` has the same shape (native
builds, push by digest, sign, verify, attest, then move the mutable tags),
but its test gate is the sidecar's integration suite
([`tests/updater.sh`](../tests/updater.sh)), and its vulnerability gate is
split: Alpine packages fail at HIGH and CRITICAL, while the vendored `cosign`
binary fails only at CRITICAL. Its HIGH findings sit in cosign's own Go
dependencies, which only a new upstream cosign build can fix; the reason is
recorded in the workflow. Those findings stay visible in code scanning (see
below). What the sidecar does at run time: [updater/README.md](../updater/README.md).

**When a release fails**, the workflow opens an issue assigned to the
maintainer — `Release pipeline failed for <tag>` or
`Updater release pipeline failed for <tag>` — on failure, cancellation or
timeout, or comments on the open one. A failure before the mutable tags move
leaves them on the previous, signed release. Recovery:
[operations.md](operations.md#release-recovery).

## Verifying releases

The images are signed by the release workflow of this repository, running on
a release tag. The certificate identity is
`https://github.com/ESITC-Paris/unbound-distroless/.github/workflows/release.yml@refs/tags/vX.Y.Z-rN`
for the resolver and `…/updater.yml@refs/tags/updater-vX.Y.Z-rN` for the
sidecar. The release workflows check, before moving any mutable tag, that
these exact commands verify:

```bash
# Resolver
cosign verify esitcparis/unbound-distroless:latest \
  --certificate-identity-regexp '^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Update sidecar
cosign verify esitcparis/unbound-autoupdate:latest \
  --certificate-identity-regexp '^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/updater\.yml@refs/tags/updater-v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Verify a digest rather than a tag when the result must hold for what you
deploy: `esitcparis/unbound-distroless@sha256:<digest>`. The same commands
work for `ghcr.io/esitc-paris/unbound-distroless` and
`ghcr.io/esitc-paris/unbound-autoupdate`. The release notes of each version
give the exact identity of that build (`--certificate-identity` instead of
the regular expression).

The broader regular expression documented before,
`'https://github.com/ESITC-Paris/unbound-distroless/.*'`, still verifies: it
accepts any workflow of this repository on any ref. Prefer the ones above.

SBOM and BuildKit provenance, from the registry:

```bash
docker buildx imagetools inspect esitcparis/unbound-distroless:latest \
  --format '{{ json .SBOM }}'
docker buildx imagetools inspect esitcparis/unbound-distroless:latest \
  --format '{{ json .Provenance }}'
```

GitHub's build-provenance attestation, from GitHub:

```bash
gh attestation verify oci://index.docker.io/esitcparis/unbound-distroless:latest \
  --repo ESITC-Paris/unbound-distroless
```

## Vulnerabilities after release

A published image can become vulnerable without any change here: Debian or
Alpine publish a fix, the base image is not rebuilt. Three mechanisms cover
this, all in [`upstream-check.yml`](../.github/workflows/upstream-check.yml)
and its scripts, exercised by [`tests/monitor.sh`](../tests/monitor.sh):

- **Base updates.** Every run of the monitor resolves the digests of the
  build and runtime bases (and of the sidecar's Alpine and cosign bases); a
  changed digest publishes a new revision of the image concerned. The
  sidecar's vendored cosign is a version tag, which never moves: the monitor
  follows the newest stable release of its major line instead
  ([`pick-version.sh`](../.github/scripts/pick-version.sh)) and publishes a
  sidecar revision built with it, after the sidecar's whole test suite.
  cosign is the binary that decides, with the Docker socket, what every
  resolver runs, so a new release is taken only once it has been out for 72
  hours ([`settled-releases.sh`](../.github/scripts/settled-releases.sh)) —
  the time in which a compromised or broken release is usually noticed and
  withdrawn — and only if its image, by digest, is signed by the Sigstore
  project's release identity. The waiting period is skipped when the
  published sidecar has findings that a rebuild does not fix: a newer cosign
  is then the likely fix. An image that does not verify is not used: the
  sidecar keeps the cosign it has and the monitor opens
  `The cosign image for the sidecar does not verify`. A new
  cosign major or a new Alpine branch is not taken unattended; for Alpine
  the monitor opens `Alpine <X.Y> is available for the sidecar`.
- **Rescan of what is published.** Every run also scans the images behind
  `latest` — resolver and sidecar, amd64 and arm64, by digest — with the
  release gates' own Trivy policy
  ([`rescan-decide.sh`](../.github/scripts/rescan-decide.sh)). When the gate
  would refuse what is published, the monitor does not guess whether a
  rebuild would help: it builds a candidate image from the current pins,
  without cache, on each architecture, and scans both. Candidates clean on
  both architectures publish a new revision. A candidate that still has
  findings on either one publishes nothing — the release's own
  gate would refuse it — and is built again an hour later, so a revision goes
  out by itself in the hour the fix becomes installable; meanwhile the
  monitor opens `Published <image> image has findings a rebuild cannot fix`,
  listing what remains (a fix not yet in the package repositories, or one
  that needs a newer base image or pinned component). A rebuild that is lost,
  fails, or is published still carrying the findings is tried again after 6,
  12 and 24 hours, then every 48 hours, and reported in `Published <image>
  image still fails the release gate after a rebuild`; no finding is ever
  given up on. Both issues are closed by the monitor once the published
  image is clean. A scanner or
  registry outage fails the run visibly and triggers no rescan-driven
  rebuild (version and base updates found by the same run still go through).
- **Visibility.** The rescan results, and the scans of every CI build on
  `main`, are uploaded to the repository's code scanning, including the
  sidecar's cosign findings that do not block. OpenSSF Scorecard
  ([`scorecard.yml`](../.github/workflows/scorecard.yml)) assesses the
  repository's practices weekly and on every push to `main`. CodeQL
  ([`codeql.yml`](../.github/workflows/codeql.yml)) analyses the workflows on
  every pull request and push to `main`.

The monitor runs when it is dispatched, hourly by design
([operations.md](operations.md)). A failed run opens or comments on the issue
`Upstream check is failing`. CI on pull requests and pushes opens no issue.

Only the current line is rescanned and rebuilt: the images behind `latest`.
When Unbound moves to a new version, the tags of the previous one stop
receiving fixes ([support policy](../SECURITY.md#supported-versions)).

**Tags.** An `X.Y.Z-rN` image tag is published once (step 5 above). The
registries themselves do not enforce this: it rests on the release workflows
and on who holds the registry credentials. A digest is the only reference
that cannot change; the release notes list it.

## DNSSEC trust anchor and root data

Three files, all fetched during the build, in a layer that is redone for
every new revision (it depends on the image revision, step 3). A local build
reuses its own cache.

**Trust anchor** (`/var/lib/unbound/root.key`). Written by `unbound-anchor`
during the build. At run time Unbound tracks the root key itself (RFC 5011,
`auto-trust-anchor-file`) and rewrites the file. The volume on
`/var/lib/unbound` is what carries that state across restarts, upgrades and
container re-creation, and through a root key rollover. Docker copies the
image's files into a named volume only when the volume is empty; after that,
the volume's own copy is the one Unbound keeps current.

**Root zone copy** (`/var/lib/unbound/root.zone`, [RFC 8806](https://www.rfc-editor.org/rfc/rfc8806)).
Not shipped in the image: a copy older than its signatures (about two weeks)
would fail its check at every start and never be replaced. Unbound transfers
it at start from the root servers listed in `unbound.conf`, keeps it current
the same way, checks its ZONEMD record (`zonemd-check: yes`),
and stores it on the volume. Answers built from it are still DNSSEC-validated,
and with `fallback-enabled: yes` normal recursion takes over if the copy is
unusable. `unbound-control list_auth_zones` shows its serial.

**Root hints** (`/etc/unbound/root.hints`). Downloaded from InterNIC during
the build, not updated at run time. Unbound needs them only to reach one root
server, then learns the current list from the root itself (priming).
