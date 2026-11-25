#!/usr/bin/env bash
# Which Debian packages of a published resolver image come from the build
# stage's harvest rather than from the distroless base. Used by
# upstream-check.yml to tell rescan-decide.sh which findings a rebuild fixes.
#
# Why this cannot be read off a Trivy report: the Dockerfile copies the
# libraries Unbound links (libc6, libssl3t64, zlib1g, libzstd1, ...) and their
# dpkg records over the base's. While the harvested version equals the base's,
# Trivy attributes the package to the OLDEST layer that has that name and
# version — a base layer — although the bytes that ship are the build stage's,
# and the build stage's `apt-get upgrade` replaces them on the next rebuild.
# Reading that as "needs a new base digest" left CVE-2026-124851 (libzstd1,
# fixed in trixie-security) unrebuilt on 2026-11-25.
#
# The answer is taken from the image itself, not from a list kept by hand:
# every dpkg record (/var/lib/dpkg/status.d/<package>) written by a layer that
# is not one of the base's.
#
# Usage: harvested-packages.sh <image> <digest> <base-diffids-file>
#   <image>   ghcr.io/<owner>/<name> or a Docker Hub <namespace>/<name>
#   <digest>  sha256:… of the published index (or of a single manifest)
#   <base-diffids-file>  the base image's layer DiffIDs, one per line
# Output: one package name per line, sorted, all platforms merged.
# Exit status: 0 with a non-empty list, 1 on any error (reason on stderr) —
# an outage must fail the run, never read as "nothing is harvested".
set -euo pipefail

[ $# -eq 3 ] || { echo "::error::usage: harvested-packages.sh <image> <digest> <base-diffids-file>" >&2; exit 1; }

python3 - "$@" <<'PY'
import gzip, io, json, re, sys, tarfile, time, urllib.error, urllib.request

image, digest, base_file = sys.argv[1:4]

def fail(msg):
    print(f"::error::harvested-packages: {msg}", file=sys.stderr)
    sys.exit(1)

if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    fail(f"'{digest}' is not a sha256 digest")
try:
    base = {l.strip() for l in open(base_file) if l.strip()}
except OSError as e:
    fail(f"base layer list unreadable ({e})")
if not base or not all(re.fullmatch(r"sha256:[0-9a-f]{64}", d) for d in base):
    fail(f"{base_file}: not a list of layer DiffIDs")

name = r"[a-z0-9]+(?:[._-][a-z0-9]+)*"
if image.startswith("ghcr.io/"):
    repo = image[len("ghcr.io/"):]
    token_url = f"https://ghcr.io/token?scope=repository:{repo}:pull"
    api = f"https://ghcr.io/v2/{repo}"
elif re.fullmatch(rf"(?:docker\.io/)?{name}/{name}", image):
    repo = image.removeprefix("docker.io/")
    token_url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    api = f"https://registry-1.docker.io/v2/{repo}"
else:
    fail(f"unsupported image '{image}' (Docker Hub or ghcr.io only)")
if not re.fullmatch(rf"{name}(?:/{name})+", repo):
    fail(f"invalid repository '{repo}'")

ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))

def get(url, headers=None, what=""):
    # Transient answers are retried; anything else is an error.
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code not in (408, 429) and e.code < 500 or attempt == 3:
                fail(f"{what} answered HTTP {e.code}")
        except OSError as e:
            if attempt == 3:
                fail(f"{what} failed ({e})")
        time.sleep(5)

try:
    token = json.loads(get(token_url, what=f"token request for {repo}"))["token"]
except (ValueError, KeyError, TypeError):
    fail(f"token response for {repo} is not usable")
auth = {"Authorization": f"Bearer {token}"}

def manifest(ref):
    try:
        return json.loads(get(f"{api}/manifests/{ref}", {**auth, "Accept": ACCEPT}, f"manifest {ref}"))
    except ValueError:
        fail(f"manifest {ref} is not JSON")

def blob(d):
    return get(f"{api}/blobs/{d}", auth, f"blob {d}")

top = manifest(digest)
if "manifests" in top:
    # Attestation manifests (platform unknown/unknown) carry no filesystem.
    refs = [m["digest"] for m in top["manifests"]
            if (m.get("platform") or {}).get("os") not in (None, "unknown")]
    manifests = [manifest(r) for r in refs]
else:
    manifests = [top]
if not manifests:
    fail(f"{digest}: no platform image in the index")

pkgs = set()
for m in manifests:
    try:
        diff_ids = json.loads(blob(m["config"]["digest"]))["rootfs"]["diff_ids"]
        layers = m["layers"]
    except (ValueError, KeyError, TypeError):
        fail("an image manifest or config without layers")
    if len(diff_ids) != len(layers):
        fail("layers and diff_ids do not line up")
    if not base & set(diff_ids):
        fail("the image shares no layer with the base it is compared to: wrong base digest")
    for diff_id, layer in zip(diff_ids, layers):
        if diff_id in base:
            continue
        data = blob(layer["digest"])
        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
                for member in tar:
                    hit = re.fullmatch(r"(?:\./)?var/lib/dpkg/status\.d/([a-z0-9][a-z0-9.+-]*)", member.name)
                    if hit and member.isfile():
                        pkgs.add(hit.group(1))
        except (tarfile.TarError, OSError, EOFError) as e:
            fail(f"layer {layer['digest']} is not a readable tar ({e})")

if not pkgs:
    fail("no harvested package found: the image always carries at least libc6")
print("\n".join(sorted(pkgs)))
PY
