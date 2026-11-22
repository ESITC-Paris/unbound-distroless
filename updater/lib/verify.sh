#!/usr/bin/env bash
# Image signature verification, fail-closed, in one of two exclusive modes:
#   keyless (default): the signing identity must be THE release workflow of
#                      this repository for that kind of image, run on a release
#                      tag, proven by the GitHub OIDC certificate;
#   key:               COSIGN_PUBLIC_KEY names a PEM public key, for a private
#                      mirror that re-signs what it serves.
# cosign's own output is written to stderr whenever verification fails: an
# operator must see WHY a signature was refused, not only that it was.

# The built-in identities, one per kind of image, fully anchored (cosign
# matches an unanchored expression ANYWHERE in the identity) with every dot
# escaped. The resolver is signed only by release.yml run on a vX.Y.Z-rN tag,
# the sidecar only by updater.yml run on an updater-vX.Y.Z-rN tag — the same
# patterns the release workflows check their own signatures against. The
# former default, any workflow on any ref of the repository, accepted a
# signature made by ci.yml, by a pull-request branch, or by the sidecar's
# pipeline for a resolver image.
COSIGN_RESOLVER_IDENTITY_REGEXP="${COSIGN_RESOLVER_IDENTITY_REGEXP:-^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$}"
COSIGN_SIDECAR_IDENTITY_REGEXP="${COSIGN_SIDECAR_IDENTITY_REGEXP:-^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/updater\.yml@refs/tags/updater-v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$}"
# COSIGN_IDENTITY_REGEXP keeps its documented meaning: when an operator sets
# it, it is used AS GIVEN for both kinds of image, exactly as before (a fork or
# a mirror re-signing under its own identity must keep working unchanged).
# Unset, the per-kind defaults above apply.
COSIGN_IDENTITY_REGEXP="${COSIGN_IDENTITY_REGEXP:-}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"

# _identity_for <kind> — the identity expression for resolver|sidecar.
_identity_for() {
  if [ -n "$COSIGN_IDENTITY_REGEXP" ]; then printf '%s\n' "$COSIGN_IDENTITY_REGEXP"; return 0; fi
  case "$1" in
    resolver) printf '%s\n' "$COSIGN_RESOLVER_IDENTITY_REGEXP" ;;
    sidecar)  printf '%s\n' "$COSIGN_SIDECAR_IDENTITY_REGEXP" ;;
    *) log_error "verify: unknown image kind '$1'"; return 1 ;;
  esac
}

# verify_image <ref> <resolver|sidecar> — 0 when the signature checks out.
# The kind is mandatory: verifying a sidecar image against the resolver's
# identity (or the reverse) is exactly the confusion the per-kind identities
# exist to rule out, so there is no default to fall back on.
verify_image() {
  local ref="$1" kind="${2:-}" out rc=0 identity
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
    identity=$(_identity_for "$kind") || return 1
    args=(--certificate-identity-regexp "$identity" --certificate-oidc-issuer "$COSIGN_ISSUER")
  fi
  # Read by the callers (refuse_unverified, self_update) to word the verdict.
  # shellcheck disable=SC2034
  VERIFY_FAILURE=""
  out=$(cosign verify "${args[@]}" "$ref" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    # shellcheck disable=SC2034
    VERIFY_FAILURE=$(_classify_cosign_failure "$out")
    return 1
  fi
  return 0
}

# _classify_cosign_failure <cosign output> — "unavailable" when cosign could
# not reach what it needed (registry, rate limit, transparency log, TUF
# mirror) and evaluated nothing; "refused" otherwise. The image is NOT
# deployable either way: only the wording and the Healthchecks message differ.
#
# This must not be steerable by whoever signed the image. cosign echoes
# signer-chosen text when it refuses — the certificate's subjects ("got
# subjects [<subject>] with issuer <issuer>"), annotations — and a subject
# such as `…/release.yml@refs/heads/TOOMANYREQUESTS` must not turn a refused
# signature into a quiet "retry later". So:
#   1. any sign that a signature was FETCHED AND EVALUATED means "refused",
#      whatever else the output says;
#   2. bracketed and quoted text (where cosign prints signer-controlled
#      values) is removed before anything else is matched;
#   3. a transport failure is recognised only in the exact shapes Go and the
#      registry client print it — `GET|HEAD … <url>: TOOMANYREQUESTS`,
#      `dial tcp …`, `…: i/o timeout`, `context deadline exceeded`, … — at the
#      end of an error line; no loose word match.
# Anything unrecognised is "refused", so an unknown failure is never reported
# as harmless.
_classify_cosign_failure() {
  local text
  if grep -qE 'no matching signatures|none of the expected identities|got subjects|expected .*identit|certificate|signature mismatch|invalid signature|failed to verify signature|verifying signature' <<<"$1"; then
    printf 'refused\n'; return 0
  fi
  text=$(sed -E 's/\[[^]]*\]//g; s/"[^"]*"//g' <<<"$1")
  if grep -qE '(GET|HEAD|POST|PUT) [^ ]+: (TOOMANYREQUESTS|UNAVAILABLE)( |:|$)|: (dial tcp [^ ]+: .*|i/o timeout|connection refused|connection reset by peer|no such host|network is unreachable|context deadline exceeded|TLS handshake timeout|server misbehaving)$|unexpected status code 5[0-9][0-9]|429 Too Many Requests$' <<<"$text"; then
    printf 'unavailable\n'
  else
    printf 'refused\n'
  fi
}

# _verify_policy <kind> — one fingerprint of everything that decides a
# verdict: the mode, the identity and issuer, the key's CONTENT (not its
# path), the tlog switch, and every cosign/Sigstore setting in the
# environment. A recorded "verified" is only reused under the same policy,
# so tightening the identity, rotating the key or changing the trust root
# makes every image be judged again. Empty when the key file cannot be read
# (verify_image then refuses anyway).
_verify_policy() {
  local key="" identity envs f
  identity=$(_identity_for "$1") || return 0
  if [ -n "${COSIGN_PUBLIC_KEY:-}" ]; then
    key=$(sha256sum < "$COSIGN_PUBLIC_KEY" 2>/dev/null | cut -d' ' -f1) || return 0
    [ -n "$key" ] || return 0
  fi
  # The trust root (SIGSTORE_ROOT_FILE, TUF_ROOT), the signature repository
  # (COSIGN_REPOSITORY), the transparency-log and CT keys… each changes what
  # a signature is checked against. Files are fingerprinted by content.
  # COSIGN_PASSWORD (signing only) is left out on purpose.
  envs=$(env | grep -E '^(COSIGN_|SIGSTORE_|TUF_ROOT=)' | grep -v '^COSIGN_PASSWORD=' | LC_ALL=C sort || true)
  for f in "${SIGSTORE_ROOT_FILE:-}" "${SIGSTORE_REKOR_PUBLIC_KEY:-}" "${SIGSTORE_CT_LOG_PUBLIC_KEY_FILE:-}" "${SIGSTORE_TSA_CERTIFICATE_FILE:-}"; do
    if [ -n "$f" ] && [ -r "$f" ]; then
      envs="$envs
file:$f=$(sha256sum < "$f" | cut -d' ' -f1)"
    fi
  done
  printf 'key=%s\nidentity=%s\nissuer=%s\nignore_tlog=%s\n%s\n' \
    "$key" "$identity" "$COSIGN_ISSUER" "${COSIGN_IGNORE_TLOG:-0}" "$envs" \
    | sha256sum | cut -d' ' -f1
}

# verify_image_once <digest-ref> <kind> — verify_image, skipped when this
# exact digest already passed under this exact policy (state keys
# VERIFIED_DIGEST, VERIFIED_POLICY). Every image the cycle is about to
# canary or recreate goes through here, including the one that was ALREADY
# running when the sidecar first saw it and the unchanged image of a
# configuration-only cycle. Remembering one digest is enough to keep the
# hourly "up to date" cycle from asking the registry for signatures every
# hour. A digest is immutable, so a verdict on it does not go stale under an
# unchanged policy. A refusal is never remembered: a signature published
# late is seen on the next cycle.
verify_image_once() {
  local ref="$1" kind="$2" policy
  policy=$(_verify_policy "$kind")
  if [ -n "$policy" ] && [ "$(state_get VERIFIED_DIGEST)" = "$ref" ] \
     && [ "$(state_get VERIFIED_POLICY)" = "$policy" ]; then
    return 0
  fi
  verify_image "$ref" "$kind" || return 1
  if [ -n "$policy" ]; then
    state_set VERIFIED_DIGEST "$ref"
    state_set VERIFIED_POLICY "$policy"
  fi
  log_info "cosign signature verified for $ref"
  return 0
}
