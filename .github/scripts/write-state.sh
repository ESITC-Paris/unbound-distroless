#!/usr/bin/env bash
# Rewrites .build-state.json for the monitor's release commit
# (upstream-check.yml), kept out of the workflow so tests/monitor.sh can
# exercise it.
#
# Inputs (environment):
#   NEW_DEBIAN NEW_DISTROLESS NEW_ALPINE NEW_COSIGN   resolved base digests
#   ACTION UPDATER_ACTION                             the decisions being published
#   RESCAN_RESOLVER RESCAN_UPDATER                    rescan status (may be empty)
#   RESCAN_RESOLVER_DIGEST RESCAN_RESOLVER_VULNS      what that status was about,
#   RESCAN_RESOLVER_TRIES                             and which attempt this is
#   RESCAN_UPDATER_DIGEST  RESCAN_UPDATER_VULNS  RESCAN_UPDATER_TRIES
#   NOW                                               epoch seconds (default: now)
#
# The four base digests are always written. The rescan attempt record
# (rescan_<image>_digest/_vulns/_at/_tries, read by rescan-decide.sh, which
# spaces the attempts out with it) is written only when this commit publishes
# a rebuild of that image AND the rescan asked for one: that is the attempt
# being recorded. Every other key already in
# the file is kept — the file is shared with whatever else reads it.
set -euo pipefail

for v in NEW_DEBIAN NEW_DISTROLESS NEW_ALPINE NEW_COSIGN; do
  [ -n "${!v:-}" ] || { echo "::error::$v is empty" >&2; exit 1; }
done

python3 - <<'PY'
import json, os, re, sys, time

env = os.environ.get
try:
    with open(".build-state.json") as f:
        state = json.load(f)
except FileNotFoundError:
    state = {}

state.update({
    "debian": env("NEW_DEBIAN"),
    "distroless": env("NEW_DISTROLESS"),
    "alpine": env("NEW_ALPINE"),
    "cosign": env("NEW_COSIGN"),
})

def record(image, publishing):
    if env(f"RESCAN_{image.upper()}", "") != "new" or not publishing:
        return
    digest = env(f"RESCAN_{image.upper()}_DIGEST", "")
    vulns = env(f"RESCAN_{image.upper()}_VULNS", "")
    tries = env(f"RESCAN_{image.upper()}_TRIES", "")
    # A record that does not identify a digest and a finding set would make
    # rescan-decide.sh compare against garbage: refuse to commit it.
    if (not re.fullmatch(r"sha256:[0-9a-f]{64}", digest) or not re.fullmatch(r"[0-9a-f]{16}", vulns)
            or not re.fullmatch(r"[1-9][0-9]{0,5}", tries)):
        print(f"::error::rescan record for {image} is malformed: digest={digest!r} vulns={vulns!r} tries={tries!r}", file=sys.stderr)
        sys.exit(1)
    state[f"rescan_{image}_digest"] = digest
    state[f"rescan_{image}_vulns"] = vulns
    state[f"rescan_{image}_at"] = str(int(env("NOW") or time.time()))
    state[f"rescan_{image}_tries"] = tries

record("resolver", env("ACTION", "") in ("version", "revision"))
record("updater", env("UPDATER_ACTION", "") == "revision")

with open(".build-state.json", "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
