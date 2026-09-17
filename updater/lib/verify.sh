#!/usr/bin/env bash
# Image signature verification, fail-closed, in one of two exclusive modes:
#   keyless (default): the signing identity must be this repository's release
#                      workflow, proven by the GitHub OIDC certificate;
#   key:               COSIGN_PUBLIC_KEY names a PEM public key, for a private
#                      mirror that re-signs what it serves.
# cosign's own output is written to stderr whenever verification fails: an
# operator must see WHY a signature was refused, not only that it was.

COSIGN_IDENTITY_REGEXP="${COSIGN_IDENTITY_REGEXP:-https://github.com/ESITC-Paris/unbound-distroless/.*}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"

# verify_image <ref> — 0 when the signature checks out.
verify_image() {
  local ref="$1" out rc=0
  local args=()
  if [ -n "${COSIGN_PUBLIC_KEY:-}" ]; then
    if [ ! -r "$COSIGN_PUBLIC_KEY" ]; then
      log_error "COSIGN_PUBLIC_KEY '$COSIGN_PUBLIC_KEY' is not readable — refusing to verify without it"
      return 1
    fi
    args=(--key "$COSIGN_PUBLIC_KEY")
    # A private mirror's signatures are typically not in the public Rekor log.
    [ "${COSIGN_IGNORE_TLOG:-0}" = 1 ] && args+=(--insecure-ignore-tlog)
  else
    args=(--certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" --certificate-oidc-issuer "$COSIGN_ISSUER")
  fi
  out=$(cosign verify "${args[@]}" "$ref" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}
