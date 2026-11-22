#!/usr/bin/env bash
# What a release run (release.yml, updater.yml) may do for its tag, given what
# is already published. Pure decision, so tests/monitor.sh can exercise it;
# the workflow's `prepare` job gathers the facts.
#
# Inputs (environment):
#   HUB_DIGEST, GHCR_DIGEST  digest of the immutable X.Y.Z-rN tag, or "absent"
#   SIGNED          yes | no — the immutable index verifies with this tag's
#                   exact signing identity on both registries (only consulted
#                   when the tag exists)
#   CURRENT         yes | no — the tag is the revision versions.env holds on
#                   main right now
#   MUTABLE_OK      yes | no — latest, X, X.Y, X.Y.Z all point at that digest
#                   on both registries
#   RELEASE_EXISTS  yes | no — the GitHub Release for the tag exists
#   REBUILD_TARGET  resolver | sidecar (named in the recovery hint)
# Output (stdout): mode=full|resume|done and digest=<sha256:…|empty>.
#   full    nothing published: build, test, publish everything
#   resume  the immutable index is published and signed, the tail is not
#           (mutable tags, attestation, GitHub Release, Docker Hub page):
#           finish it without rebuilding
#   done    fully published already (a duplicate dispatch): do nothing
# Exit 1 with the reason on stderr when the run must not proceed.
#
# Why resume is restricted to the CURRENT revision: finishing an old tag
# would move `latest` back to it — the very hole the published-tag guard
# closes. Only the revision main holds now can be the newest one.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
hint="publish a new revision instead: gh workflow run upstream-check.yml -f rebuild=${REBUILD_TARGET:-<resolver|sidecar>}"
for v in HUB_DIGEST GHCR_DIGEST; do
  [[ "${!v:-}" =~ ^(absent|sha256:[0-9a-f]{64})$ ]] || die "$v='${!v:-}' is neither a digest nor 'absent'"
done
for v in SIGNED CURRENT MUTABLE_OK RELEASE_EXISTS; do
  case "${!v:-}" in yes|no) ;; *) die "$v must be yes or no, got '${!v:-}'" ;; esac
done

if [ "$HUB_DIGEST" = absent ] && [ "$GHCR_DIGEST" = absent ]; then
  printf 'mode=full\ndigest=\n'; exit 0
fi
[ "$HUB_DIGEST" != absent ] && [ "$GHCR_DIGEST" != absent ] \
  || die "the immutable tag exists on one registry only (Docker Hub: $HUB_DIGEST, GHCR: $GHCR_DIGEST) — an X.Y.Z-rN tag is never re-pushed; $hint"
[ "$HUB_DIGEST" = "$GHCR_DIGEST" ] \
  || die "the immutable tag points at different digests (Docker Hub: $HUB_DIGEST, GHCR: $GHCR_DIGEST); $hint"
[ "$SIGNED" = yes ] \
  || die "the immutable tag exists ($HUB_DIGEST) but does not verify with this tag's signing identity (an earlier run failed before signing, or Sigstore is unreachable — then retry later); it is never re-pushed: $hint"

# An older revision's mutable tags have legitimately moved on to newer
# releases: for it, "complete" means signed and released.
if [ "$RELEASE_EXISTS" = yes ] && { [ "$MUTABLE_OK" = yes ] || [ "$CURRENT" = no ]; }; then
  echo "::notice::already published at $HUB_DIGEST, with its GitHub Release — nothing to do (duplicate dispatch?)" >&2
  printf 'mode=done\ndigest=%s\n' "$HUB_DIGEST"; exit 0
fi
[ "$CURRENT" = yes ] \
  || die "the tag is published and signed but has no GitHub Release, and it is not the revision main holds now: finishing it would move latest backwards. Refused."
echo "published and signed at $HUB_DIGEST; finishing the incomplete release (mutable tags in place: $MUTABLE_OK, GitHub Release: $RELEASE_EXISTS)" >&2
printf 'mode=resume\ndigest=%s\n' "$HUB_DIGEST"
