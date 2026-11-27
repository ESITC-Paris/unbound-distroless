# Operations

For the maintainer: how the automation is started and supervised, what to do
when it stops or a release fails, and the GitHub settings it relies on.

## What runs, and what starts it

| Workflow | Started by | Does |
|---|---|---|
| [`upstream-check.yml`](../.github/workflows/upstream-check.yml) (the monitor) | [`deploy/unbound-upstream-check`](../deploy/unbound-upstream-check), from cron on an ESITC host, hourly, through the `workflow_dispatch` API; or by hand | Rescans the published images; checks for a new Unbound release and for new base image digests; if anything is to publish, commits `versions.env` and `.build-state.json` to `main`, creates the release tags and dispatches the release workflows; checks that the current release of each image is really out, and dispatches it again if not |
| [`release.yml`](../.github/workflows/release.yml), [`updater.yml`](../.github/workflows/updater.yml) | A dispatch on the release tag, by the monitor or by hand | Build, test, sign and publish one release ([trust.md](trust.md#from-source-to-registry)). Each workflow has its own concurrency group (`publish-resolver`, `publish-sidecar`): the two can run at the same time, and further dispatches of the same workflow queue (up to 100) instead of being cancelled |
| [`ci.yml`](../.github/workflows/ci.yml) | Pull requests; pushes to `main` that change more than Markdown | Lint, the resolver's test suites, the sidecar's integration suite, the Trivy gates |
| [`scorecard.yml`](../.github/workflows/scorecard.yml) | Weekly schedule, pushes to `main` | OpenSSF Scorecard |
| [`codeql.yml`](../.github/workflows/codeql.yml) | Pull requests, pushes to `main` | CodeQL static analysis of the workflows themselves (`actions` language), reported in code scanning |

The decisions live in scripts tested by [`tests/monitor.sh`](../tests/monitor.sh):
[`decide-updates.sh`](../.github/scripts/decide-updates.sh) (what to publish),
[`rescan-decide.sh`](../.github/scripts/rescan-decide.sh) (the rescan),
[`release-health.sh`](../.github/scripts/release-health.sh) (is the current
release out), [`release-mode.sh`](../.github/scripts/release-mode.sh) and
[`release-facts.sh`](../.github/scripts/release-facts.sh) (what a release run
may do), [`hold.sh`](../.github/scripts/hold.sh) (what is frozen:
[Rolling back a release](#rolling-back-a-release)). Only stable Unbound versions are
picked up (`release-X.Y.Z` tags; release candidates do not match), and the
version only ever moves up.

**Why the monitor has no `schedule`.** An external dispatch is not subject to
GitHub's 60-day inactivity auto-disable of scheduled workflows, nor to the
scheduler's delays under load, and every secret and every decision stays in
the repository: the cron host only says "run now". The cost: nothing on
GitHub notices when the trigger goes quiet. A dead host, a lost crontab or an
expired token means no runs, and every GitHub-side alarm stays silent because
nothing fails. This happened: the trigger stopped on 2026-09-18, and Unbound
1.26.2 (released 2026-10-21) went unbuilt for six weeks. The Healthchecks.io
check below is therefore required, not optional. Scorecard is the one
scheduled workflow: it is not on the release path, so a late run costs only a
stale score.

## The trigger script

Each run of `deploy/unbound-upstream-check` (covered by
[`tests/trigger.sh`](../tests/trigger.sh), without network):

1. pings the Healthchecks check's `/start`;
2. dispatches the monitor and requires HTTP 204;
3. waits for a new run of the monitor to appear (`POLL_ATTEMPTS` ×
   `POLL_INTERVAL`, 90 s by default): an accepted request is not a started
   run, and a workflow disabled on GitHub accepts dispatches and starts
   nothing;
4. asks GitHub for the newest run of the monitor that **succeeded**, and
   fails when it started `MAX_SUCCESS_AGE_HOURS` (3) or more hours ago, or
   when there is none, or when the answer cannot be read — after the
   dispatch, so the monitor still runs. Runs that start and then fail, time
   out or are cancelled every hour are a monitor that does nothing;
5. reads the token's expiry date from the API response headers: when 14 or
   fewer whole days remain (less than 15 days), it warns on stderr, at most
   once a day; when 3 or fewer remain (less than 4 days), the run fails —
   also after the dispatch;
6. pings the check with `run <id> started` on success, or `/fail` with the
   reason.

It does not wait for the run it started to finish: that run's own failure is
reported by the monitor itself (see Supervision), and by step 4 of the
following hours if it lasts. It prints nothing on success (with `VERBOSE=1`,
the `run <id> started` line), and on failure exits 1 with the reason on
stderr. A Healthchecks ping that fails prints a warning and does not fail the
run. With `HC_URL` empty it says so on stderr once a day: nothing would then
report a host that stops.

Settings, read from `/etc/unbound-distroless/trigger.conf` (`KEY=VALUE`
lines, sourced; another path with `UNBOUND_TRIGGER_CONF`):

| Setting | Default | |
|---|---|---|
| `TOKEN_FILE` | `/etc/unbound-distroless/github-token` | Fine-grained token, Actions read and write on this repository only |
| `HC_URL` | empty | Healthchecks.io ping URL. Empty disables the pings — and with them the only alarm for runs that stop |
| `REPO` | `ESITC-Paris/unbound-distroless` | |
| `WORKFLOW` | `upstream-check.yml` | |
| `REF` | `main` | |
| `STATE_DIR` | `/var/lib/unbound-distroless` | Remembers the day each once-a-day warning was last printed |
| `MAX_SUCCESS_AGE_HOURS` | `3` | Fail when the newest successful run of the monitor started this many hours ago or more. `0` disables the check |
| `EXPIRY_WARN_DAYS` | `14` | Warn when this many whole days or fewer remain |
| `EXPIRY_FAIL_DAYS` | `3` | Fail when this many whole days or fewer remain |
| `POLL_ATTEMPTS` | `9` | Checks for the new run… |
| `POLL_INTERVAL` | `10` | …this many seconds apart |
| `VERBOSE` | empty | Non-empty: print `run <id> started` on success |

### Setting it up

1. **Token.** GitHub → Settings → Developer settings → Fine-grained personal
   access tokens: repository access `ESITC-Paris/unbound-distroless` only,
   permission Actions: read and write, nothing else. Note the expiry date.
2. **Healthchecks.io check**, one per trigger host: period 1 hour, grace
   3 hours. It alerts when no success ping has arrived for period plus grace
   (4 hours: one missed run is noise, several are an outage), and at once on
   a `/fail` ping.
3. **Install** on the host:

   ```bash
   sudo install -m 755 deploy/unbound-upstream-check /usr/local/bin/
   sudo install -d -m 700 /etc/unbound-distroless
   sudo sh -c 'umask 077; printf "%s\n" "github_pat_XXXX" > /etc/unbound-distroless/github-token'
   sudo sh -c 'printf "HC_URL=https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\n" > /etc/unbound-distroless/trigger.conf'
   sudo VERBOSE=1 /usr/local/bin/unbound-upstream-check   # prints "run <id> started"
   ```

4. **Cron:**

   ```cron
   MAILTO=admin@esitc-paris.fr
   17 * * * * /usr/local/bin/unbound-upstream-check
   ```

   Cron mails whatever the script prints: failures and expiry warnings. That
   needs a working mail transfer agent on the host.

Renewing the token: write the new one into `TOKEN_FILE`; nothing else
changes.

## Supervision

Three layers. Only the first notices runs that do not happen, and it is also
the one that does not depend on GitHub to say that GitHub's side is broken.

1. **Trigger (Healthchecks.io and cron mail).** The check alerts 4 hours
   after the last successful dispatch, whatever the cause — dead host, cron,
   token, GitHub API, disabled workflow — and immediately when the script
   fails. A dead host mails nothing; that is what this layer is for. The
   script also fails when no run of the monitor has **succeeded** for 3
   hours: the issues of layer 2 are opened by the workflow that is failing,
   with its own token, and reach the maintainer through GitHub's
   notifications; this alarm needs none of that.
2. **Workflows (GitHub issues).** A monitor run that fails or times out —
   including a failed rescan — opens or comments on
   `Upstream check is failing`. A release that fails, is cancelled or times
   out opens or comments on `Release pipeline failed for <tag>` or
   `Updater release pipeline failed for <tag>`. A current release the monitor
   could not complete after three runs opens `Release <tag> is incomplete`.
   The rescan opens
   `Published <image> image still fails the release gate after a rebuild` or
   `Published <image> image has findings a rebuild cannot fix`
   ([trust.md](trust.md#vulnerabilities-after-release)), and closes them
   itself once the published image is clean. The monitor also opens, and
   closes by itself, `A new Unbound version cannot be adopted` (the release
   could not be verified or pinned; base updates and rescan rebuilds of the
   current version go on meanwhile), `The cosign image for the sidecar does
   not verify` (the sidecar keeps the cosign it has) and `Automatic releases
   are on hold` (for as long as [`.github/monitor-hold`](../.github/monitor-hold)
   lists an image). All are assigned to
   `euca01`; GitHub notifies according to that account's settings. A run
   that fails before its first step (startup failure) opens nothing. CI opens
   no issue.
3. **Publication.** Every release appears on the
   [releases page](https://github.com/ESITC-Paris/unbound-distroless/releases);
   Watch → Custom → Releases notifies. Successful releases open no issue.

## When runs stop

1. On the trigger host, `sudo VERBOSE=1 /usr/local/bin/unbound-upstream-check`
   prints the reason: HTTP 401 is an expired or revoked token; "no new run …
   appeared" means the workflow is disabled on GitHub (re-enable it in the
   Actions tab); "no run … has succeeded for N h" means the runs start and
   fail — open the newest one in the Actions tab, and the issue
   `Upstream check is failing` if it exists.
2. Catch up with one run by hand (below). A single run sees everything that
   was missed: the newest Unbound version, every base digest change, and the
   current findings of the published images.

## Manual operations

```bash
# Run the monitor now
gh workflow run upstream-check.yml --repo ESITC-Paris/unbound-distroless
```

### Release recovery

A failed release usually needs nothing by hand. Each hour the monitor checks
that the revision `versions.env` holds is really out, for each image: the
immutable `X.Y.Z-rN` tag on both registries, `latest`, `X`, `X.Y` and `X.Y.Z`
on its digest, and the GitHub Release. If not, and no run of that release is
queued or running, it dispatches the release again on the same tag — at most
three runs in total — then opens `Release <tag> is incomplete`
([`release-health.sh`](../.github/scripts/release-health.sh)). The check is
skipped for an image the same monitor run is already re-releasing.

What a run dispatched on an existing tag does is decided from what is
published ([`release-mode.sh`](../.github/scripts/release-mode.sh)):

| Already published | The run |
|---|---|
| Nothing, and the tag is the revision `main` holds now | Builds, tests and publishes everything |
| Nothing, and the tag is an older revision | Refuses: publishing it would move `latest` and the other mutable tags back to an old build |
| The immutable tag on both registries, same digest, signed by this tag's run; not all of the rest; the tag is the revision `main` holds now | Finishes on that digest without rebuilding or re-signing: verifies the signatures, attests, moves the mutable tags, creates the GitHub Release and updates the Docker Hub page |
| All of it (or, for an older revision, signed and with its GitHub Release) | Nothing; the run succeeds with "already published … duplicate dispatch?" |
| Anything else: the tag on one registry only, different digests, no valid signature from this tag's run, or an older revision without its GitHub Release | Refuses, and names the fix below |

The same dispatch by hand, if the monitor has given up and the cause is
fixed:

```bash
gh workflow run release.yml --repo ESITC-Paris/unbound-distroless \
  --ref vX.Y.Z-rN -f tag=vX.Y.Z-rN
gh workflow run updater.yml --repo ESITC-Paris/unbound-distroless \
  --ref updater-vX.Y.Z-rN -f tag=updater-vX.Y.Z-rN
```

An `X.Y.Z-rN` image tag is never pushed twice, and an older revision is never
finished (it would move `latest` backwards). When a run is refused — an
unsigned or split immutable tag — publish the next revision of the current
tree instead; the mutable tags stay on the previous signed release
meanwhile. The same input forces a rebuild for any other reason:

```bash
gh workflow run upstream-check.yml --repo ESITC-Paris/unbound-distroless \
  -f rebuild=resolver          # or sidecar, or both
```

If the monitor pushed tags but could not dispatch a release, it tries five
times, then fails the run; the next hour's release check dispatches it.

### Rolling back a release

A release that passed every gate and is still wrong: the resolvers that run
the sidecar took it within the hour, after their own canary. There is no
"unpublish". An `X.Y.Z-rN` tag is never pushed twice, an older revision is
never finished or republished, and the sidecar refuses an image whose
version is older than the one it runs (`ALLOW_DOWNGRADE`). The way back is
forward: a new revision that does not have the fault.

1. **Stop the monitor from publishing that image.** Add `resolver` or
   `sidecar` to [`.github/monitor-hold`](../.github/monitor-hold) through a
   pull request. From the next run, no new Unbound version, base digest or
   rescan result publishes that image, its recorded base digests stay as
   they are, and its current release is not repaired or dispatched again.
   The other image is not affected. The monitor opens
   `Automatic releases are on hold` and keeps it open.
2. **On the hosts, if the fault cannot wait** for step 4: pin the last good
   image by digest ([production.md](production.md), runbooks; the digest is
   in the release notes of the previous revision). A host pinned by digest
   no longer follows the tag.
3. **Fix `main`**: revert or correct the change, through a pull request like
   any other. When the fault came with a base image or a package and not
   with a commit here, there is nothing to revert: the hold of step 1 is
   what keeps the previous base digests in `.build-state.json`.
4. **Publish the next revision** from what `main` now pins. `rebuild` works
   on a held image, and is the only thing that does:

   ```bash
   gh workflow run upstream-check.yml --repo ESITC-Paris/unbound-distroless \
     -f rebuild=resolver          # or sidecar
   ```

   It is a normal release: same tests, same gates, signed, and the mutable
   tags move to it. The sidecars deploy it as an update. A base image named
   by a moving tag is built by the digest the repository records, so a
   rebuild under a hold gets the base of the last good build; the packages
   installed on top of it (`apt-get upgrade`, `apk upgrade`) are the current
   ones.
5. **Lift the hold** once the cause is understood: remove the line, through
   a pull request. The monitor then picks up everything it skipped, in one
   run, and closes the issue.

Going back to an older **Unbound version** (not revision) is not something
the pipeline does: versions only move up, here and in the sidecar. Hold the
resolver, pin the hosts to the last release of the previous version by
digest, and wait for the upstream fix.

## Repository settings

The GitHub configuration lives in [`.github/settings/`](../.github/settings/):
three ruleset files and [`apply.sh`](../.github/settings/apply.sh), which sets
everything below and can be re-run at any time to undo a drift.

| Area | Setting |
|---|---|
| `main` | No deletion, no force-push; changes only through a pull request whose checks `lint`, `build-and-test`, `updater (classic)` and `updater (containerd)` pass; no review required (one maintainer). Bypass: the monitor's deploy key only. |
| Release tags `v*`, `updater-v*` | Creation: the monitor's deploy key and repository admins only. Update and deletion: nobody. |
| Environments | `release` (Docker Hub credentials), usable from `v*` and `updater-v*` tags only; `monitor` (the deploy key), usable from `main` only. No reviewers and no wait timer: either would stop unattended releases. |
| Actions | Default token read-only; workflows cannot approve pull requests; only GitHub-owned actions and the listed third-party ones, by full SHA. |
| Security | Private vulnerability reporting, Dependabot alerts and security updates, secret scanning with push protection. |
| Presentation | Description and topics. |

Applying or re-applying, as a repository admin with `gh` and `python3`:

```bash
.github/settings/apply.sh --dry-run --bot-bypass deploy-key   # prints the plan, changes nothing
.github/settings/apply.sh --bot-bypass deploy-key
```

`--dry-run` makes only read requests and prints each planned call with its
body (`PLAN <METHOD> <path>`) and what would be created or updated. Without
`--bot-bypass`, the `main` and tag-creation rulesets are skipped:
they would block the monitor's push. The first time, follow the order at the
top of `apply.sh`: push the workflow changes; create the deploy key and its
`MONITOR_DEPLOY_KEY` secret in the `monitor` environment by hand (the script
never handles keys); move `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` into the
`release` environment and delete the repository-level copies; run the script
with `--dry-run`, read the plan, then without it;
then check that a force-push to `main`, a `v*` tag pushed by anyone else and
moving an existing tag are all refused, and that the next automated release
completes. If deploy keys cannot be bypass actors, `--bot-bypass app:<id>`
names a GitHub App instead. Until the deploy key exists, the monitor pushes
with `GITHUB_TOKEN`, as before.

## The removed host-side updater

`deploy/` used to hold a host-side `unbound-autoupdate` script with a systemd
timer. It has been removed; it could not update a Compose deployment that
follows `:latest`. Its replacement, and the commands to uninstall it, are in
[updater/README.md](../updater/README.md).
