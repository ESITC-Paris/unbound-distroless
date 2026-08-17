# Operations

How the automatic update pipeline is scheduled and supervised.

## Scheduling model

The update monitor (`.github/workflows/upstream-check.yml`) has **no GitHub
`schedule` trigger**. It is invoked hourly from ESITC infrastructure through
the `workflow_dispatch` API. Rationale:

- external dispatch is exempt from GitHub's 60-day inactivity auto-disable
  of scheduled workflows;
- it is not subject to GitHub scheduler congestion (cron triggers can be
  delayed or skipped under load);
- the check logic, secrets, and publishing stay entirely inside the audited
  repository — the external component is a dumb, replaceable trigger.

## One-time setup

### 1. Create a fine-grained GitHub token

GitHub → Settings → Developer settings → Fine-grained personal access tokens:

- **Repository access:** only `ESITC-Paris/unbound-distroless`
- **Permissions:** Actions → *Read and write* (nothing else)
- Note the expiration date — token renewal is an operational duty (see
  Supervision below for how expiry is detected).

### 2. Install the trigger on a server

`/usr/local/bin/unbound-upstream-check`:

```bash
#!/bin/sh
# Triggers the unbound-distroless update monitor on GitHub.
# The token file must contain the fine-grained PAT, mode 600, owner root.
set -eu

TOKEN_FILE=/etc/unbound-distroless/github-token
API=https://api.github.com/repos/ESITC-Paris/unbound-distroless/actions/workflows/upstream-check.yml/dispatches

HTTP_CODE=$(curl -sS -o /tmp/upstream-check-trigger.err -w '%{http_code}' \
  --retry 3 --retry-delay 10 \
  -X POST \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H "Accept: application/vnd.github+json" \
  "$API" -d '{"ref":"main"}')

if [ "$HTTP_CODE" != "204" ]; then
  echo "upstream-check dispatch failed (HTTP $HTTP_CODE):" >&2
  cat /tmp/upstream-check-trigger.err >&2
  exit 1
fi
```

```bash
sudo install -m 755 unbound-upstream-check /usr/local/bin/
sudo install -d -m 700 /etc/unbound-distroless
sudo sh -c 'umask 077; printf "%s\n" "github_pat_XXXX" > /etc/unbound-distroless/github-token'
```

### 3. Cron entry

```cron
MAILTO=admin@esitc-paris.fr
17 * * * * /usr/local/bin/unbound-upstream-check
```

The script is silent on success; cron therefore emails only on failure
(bad token, expired token, network or API error).

## Supervision

Three independent layers:

1. **Trigger layer (this server):** any non-204 response — including an
   expired token (HTTP 401) — makes the script fail, and cron `MAILTO`
   reports it. Optionally add a dead-man's switch (e.g. a Healthchecks.io
   ping appended to the cron line) to also detect the server itself going
   quiet.
2. **Workflow layer (GitHub):** if a triggered check or a release pipeline
   fails, the workflow opens an issue assigned to the administrator
   (guaranteed e-mail / mobile notification), deduplicated per problem.
3. **Publication layer:** every published release opens a notification issue
   and appears on the
   [releases page](https://github.com/ESITC-Paris/unbound-distroless/releases)
   (subscribe via Watch → Custom → Releases).

## Manual operations

```bash
# Run the update check immediately
gh workflow run upstream-check.yml --repo ESITC-Paris/unbound-distroless

# Re-run a release for an existing tag
gh workflow run release.yml --repo ESITC-Paris/unbound-distroless \
  --ref vX.Y.Z-rN -f tag=vX.Y.Z-rN
```

Only stable upstream versions are ever published: the version detector
matches `release-X.Y.Z` tags exactly, so release candidates and pre-releases
never trigger a build.
