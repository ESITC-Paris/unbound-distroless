# Operations

How the automatic update pipeline is scheduled and supervised.

## Scheduling model

The update monitor (`.github/workflows/upstream-check.yml`) has **no GitHub
`schedule` trigger**. It is invoked hourly from ESITC infrastructure by
[`deploy/unbound-upstream-check`](../deploy/unbound-upstream-check), through
the `workflow_dispatch` API. Rationale:

- external dispatch is exempt from GitHub's 60-day inactivity auto-disable
  of scheduled workflows;
- it is not subject to GitHub scheduler congestion (cron triggers can be
  delayed or skipped under load);
- the check logic, secrets, and publishing stay entirely inside the audited
  repository — the external component only says "run now".

The price of that choice: **nothing on GitHub can notice the trigger going
quiet.** A dead host, a lost crontab, a stopped cron daemon or an expired
token simply means no more runs, and every GitHub-side alarm (failure
issues, red runs) stays silent because nothing fails — nothing happens. This
is not theoretical: the trigger stopped on 2026-09-18 and Unbound 1.26.2
(released 2026-10-21) went unbuilt for six weeks before anyone looked at the
Actions tab. The Healthchecks.io dead-man's switch below is therefore part of
the setup, not an option.

What the trigger script does on every run (covered by `tests/trigger.sh`):

1. pings the Healthchecks check's `/start`;
2. dispatches the workflow and requires HTTP 204;
3. **waits for a new run to actually appear** (up to 90 s) — an accepted
   request is not a started run; a workflow disabled on GitHub is the
   typical gap;
4. reads the token's expiry date from the API response: a warning on stderr
   once a day when it is within 14 days (cron mails it), a failed run when
   it is within 3 days;
5. pings the check with the run id on success, or `/fail` with the reason.

It is silent on success and exits 1 with the reason on stderr otherwise.

## One-time setup

### 1. Create a fine-grained GitHub token

GitHub → Settings → Developer settings → Fine-grained personal access tokens:

- **Repository access:** only `ESITC-Paris/unbound-distroless`
- **Permissions:** Actions → *Read and write* (nothing else)
- Note the expiration date — token renewal is an operational duty (the
  script warns 14 days ahead and fails 3 days ahead, see Supervision below).

### 2. Create the Healthchecks check

One check per trigger host, period **1 hour**, grace **3 hours** (one missed
run is noise; three in a row is an outage). Note its ping URL.

### 3. Install the trigger on a server

```bash
sudo install -m 755 deploy/unbound-upstream-check /usr/local/bin/
sudo install -d -m 700 /etc/unbound-distroless
sudo sh -c 'umask 077; printf "%s\n" "github_pat_XXXX" > /etc/unbound-distroless/github-token'
sudo sh -c 'printf "HC_URL=https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\n" > /etc/unbound-distroless/trigger.conf'
sudo VERBOSE=1 /usr/local/bin/unbound-upstream-check   # prints "run <id> started"
```

The script reads `/etc/unbound-distroless/trigger.conf` (plain `KEY=VALUE`
lines); every setting and its default is documented at the top of the
script.

### 4. Cron entry

```cron
MAILTO=admin@esitc-paris.fr
17 * * * * /usr/local/bin/unbound-upstream-check
```

Cron mails whatever the script prints, and it prints only on failure or when
the token is about to expire.

## Supervision

Three layers. Only the first one can detect the *absence* of runs; the other
two react to runs that happen.

1. **Trigger layer (Healthchecks + cron mail):** the check alerts when no
   successful run has been reported for 3 hours, whatever the cause — dead
   host, cron, token, GitHub API, disabled workflow, failed run. Cron's
   `MAILTO` additionally mails the reason whenever the script fails or warns
   (this needs a working MTA on the host; a dead host mails nothing, which
   is what the Healthchecks layer is for).
2. **Workflow layer (GitHub):** if a triggered check or a release pipeline
   fails or is cancelled by its timeout, the workflow opens an issue assigned
   to the administrator, deduplicated per problem; GitHub notifies the
   assignee according to their notification settings. A failure before the
   first step runs (startup failure) opens no issue.
3. **Publication layer:** every published release (resolver `vX.Y.Z-rN` and
   sidecar `updater-vX.Y.Z-rN`) appears on the
   [releases page](https://github.com/ESITC-Paris/unbound-distroless/releases).
   Successful releases open no issue — subscribe via Watch → Custom →
   Releases to be notified; issues are reserved for failures.

**Token renewal:** fine-grained tokens expire. Renewing means writing the
new token into `/etc/unbound-distroless/github-token`; nothing else changes.

## When runs stop

If the Healthchecks alert fires, or the Actions tab shows no "Upstream check"
run for hours:

1. On the trigger host, `sudo VERBOSE=1 /usr/local/bin/unbound-upstream-check`
   prints the reason: HTTP 401 is an expired or revoked token; "no new run
   appeared" means the workflow is disabled on GitHub (re-enable it in the
   Actions tab).
2. Catch up: run the check by hand (below). One run detects everything that
   was missed — the newest upstream version and any base-image change — and
   publishes it.

## Manual operations

```bash
# Run the update check immediately
gh workflow run upstream-check.yml --repo ESITC-Paris/unbound-distroless

# Re-run a release for an existing tag. This republishes the tag with a new
# digest (root data is re-downloaded at build time); a sidecar pinned to it
# will canary and deploy that new digest.
gh workflow run release.yml --repo ESITC-Paris/unbound-distroless \
  --ref vX.Y.Z-rN -f tag=vX.Y.Z-rN
gh workflow run updater.yml --repo ESITC-Paris/unbound-distroless \
  --ref updater-vX.Y.Z-rN -f tag=updater-vX.Y.Z-rN
```

Only stable upstream versions are ever published: the version detector
matches `release-X.Y.Z` tags exactly, so release candidates and pre-releases
never trigger a build.

## Automatic server-side updates

Production servers keep themselves current with the [`updater/`](../updater/)
sidecar: cosign verification, `unbound-checkconf` preflight, a canary run on
a clone of the production state with the declared configuration, a post-swap
gate that checks the container really moved to the declared image, and an
automatic rollback with quarantine. The host-side script that used to live in
`deploy/` has been removed; see [deploy/README.md](../deploy/README.md) for
why and how to uninstall it.
