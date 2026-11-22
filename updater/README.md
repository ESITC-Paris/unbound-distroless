# unbound-autoupdate

A sidecar for a Docker Compose project running `unbound-distroless`. Every
hour (`INTERVAL`) it checks whether the resolver's declared image or configuration has
changed; when one has, it verifies the image's signature, tries image and
configuration together on a copy of production's state, replaces the
resolver, checks it, and rolls back if the checks fail. The same image serves
a Prometheus `/metrics` endpoint for the resolver and for itself, and keeps
itself up to date.

## What a cycle does

In this order (`updater/unbound-autoupdate`):

1. **Lock.** One cycle at a time per state directory. A cycle that finds the
   lock taken ends at once (exit 2, nothing recorded, no ping).
2. **Discover.** The resolver is the one service of the sidecar's own Compose
   project described under `TARGET_SERVICE` ([Variables](#variables)). The
   project's declared state is read with `docker compose config`, using the
   compose files recorded on the resolver container; the running state with
   `docker inspect`. When no resolver container runs, the cycle waits up to
   `DISCOVER_WAIT` seconds for one.
3. **Finish an interrupted swap.** If the previous cycle stopped between the
   start of a swap and its verdict (state key `SWAP_INTENT`), a stopped or
   only created resolver container is accepted, and:
   - a resolver running neither the previous nor the new image: the intent
     is dropped;
   - the previous image still running, production unchanged: the intent is
     cleared, and leftover created or exited containers of the service are
     removed;
   - the new image running: it gets the post-swap checks of step 13, and is
     rolled back if they fail;
   - otherwise: the previous image is put back (step 14), without
     quarantine since the new image never ran.

   A recovery that fails is not tried again: the intent is cleared and the
   cycle ends `critical`.
4. **Name what runs.** The images the resolver and the sidecar run are given a
   local name of the sidecar's own, `<repository>:autoupdate-<project>-<service>`,
   so their local records survive later tag moves.
5. **Resolve and pull by digest.** The declared tag is resolved to the digest
   it names in the registry now, with a `HEAD` request for its manifest (the
   registry's token protocol, the static credentials of `DOCKER_CONFIG`;
   plain HTTP only for a registry on a loopback address). Where that fails,
   the Docker daemon is asked (Engine API `GET /distribution/<ref>/json`, with
   the daemon's registry configuration). That digest is pulled unless it is
   already present. No tag moves: until the swap, the operator's tag keeps
   naming the image that runs.
6. **Compare.** The image changed if the pulled image's ID differs from the
   running container's. The configuration changed if the SHA-256 fingerprint
   of the declared bind mounts differs from the one recorded (only with
   `WATCH_CONFIG=1`). The fingerprint covers every file of every bind mount
   of the resolver service except those under `/var/lib/unbound` and
   `FINGERPRINT_EXCLUDE`; directories are expanded with symbolic links
   followed, and a directory with no file or a link to a missing file stops
   the cycle.
7. **Baseline.** On the first cycle (no recorded fingerprint) the fingerprint
   and the running image are recorded and a `baseline` notification is sent;
   the cycle continues.
8. **Nothing changed** (and not `check` mode): the running image's signature
   is verified if this digest has not passed under the current verification
   settings yet; then self-update (step 15). The cycle ends `up_to_date`.
9. **Quarantine.** An image or a configuration that failed after a swap is
   not tried again before `RETRY_AFTER`, unless it changes. Either quarantine
   ends the cycle, including when the other axis carries a change that is not
   quarantined.
10. **Major version.** The leading number of the
    `org.opencontainers.image.version` labels of the running container and the
    new image must be equal, unless `ALLOW_MAJOR=1`. A new label without a
    leading number is refused the same way; a running label without one, or a
    missing label, skips this check with a warning in the log.
11. **Host network.** A sidecar with `network_mode: host` cannot join the
    canary's network: a cycle with a change stops here.
12. **Verify, downgrade, preflight, canary.** The image to deploy (also the
    unchanged image of a configuration-only change) is verified with cosign,
    once per digest and verification settings. A new image whose version
    label (`X.Y.Z` or `X.Y.Z-rN`) is older than the running one is then
    refused, unless `ALLOW_DOWNGRADE=1`; revisions are compared only when
    both labels carry one, and a label of another form skips this check with
    a warning. Its `unbound-checkconf` then checks the declared
    configuration. The canary is that image started on an isolated
    network with a copy of production's `/var/lib/unbound` volume, the
    declared bind mounts read-only, and the declared `read_only`, `tmpfs`,
    `environment`, `ulimits` and `sysctls`; its capabilities are always
    `--cap-drop=ALL --cap-add=NET_BIND_SERVICE` with `no-new-privileges`. It
    must answer within 90 s, then pass the validation below. In `check` mode
    the cycle ends here (`check_ok`).
13. **Swap.** The resolver's cache is exported (`KEEP_CACHE`); the intent is
    recorded (`SWAP_INTENT`); the operator's tag is pointed at the verified
    image and `docker compose up -d --no-deps --pull never` recreates the
    service from the operator's own files (`--force-recreate` when only the
    configuration changed). The new container must be a different container,
    run the verified image ID, answer within 45 s and pass the validation.
    Then the cache is reloaded, quarantines are cleared and the cycle ends
    `updated`, followed by self-update.
14. **Rollback**, when step 13 fails: the operator's tag is pointed back at
    the previous image and the service is recreated with
    `--force-recreate --pull never`. For a service declared by digest, or by a
    tag of another repository than the previous image's, no tag can name the
    previous image: an override file in the state directory (`rollback.yml`)
    names its keep name instead, and the declared tag is put back on what it
    named before the swap. A new container running the previous image must
    then pass the validation. What changed (image, configuration or both) is
    quarantined. The configuration files themselves are not reverted. A
    rollback that fails leaves `SWAP_INTENT` set: the next cycle tries once
    more (step 3).
15. **Self-update**, after `up_to_date` and `updated`: see
    [Self-update](#self-update).

**Validation**, for the canary and after a swap or rollback: `VALIDATE_DOMAIN`
resolves with NOERROR over UDP and over TCP; the root SOA carries the AD flag
(unless `REQUIRE_DNSSEC=0`); with `STRICT_BOGUS_CHECK=1`, `dnssec-failed.org`
fails with SERVFAIL. Each query is tried up to four times, 5 s apart.

**Signals.** SIGTERM ends a cycle (status `error`), except between the start
of a swap and its verdict: the swap or rollback finishes first. A container
killed in between (stop timeout, reboot), even inside `docker compose up`,
is finished by the next cycle (step 3); `stop_grace_period: 2m` on the sidecar service gives a swap time to
finish.

After every cycle, the operator's tags name the images that run, so a plain
`docker compose up -d` recreates nothing. The exception is a rollback through
`rollback.yml`: the compose file then names something other than what runs
(for a digest, the failed image), and `up -d` deploys what it names. Only `docker compose pull` (or
`pull_policy: always`) followed by `up -d` would deploy what the registry
serves under the tag, without the sidecar's checks.

On the containerd image store (the default of a fresh Docker Engine 29
install), this needs Docker Compose 5.5.0 or later on the host
(`docker compose version`). The sidecar recreates containers with the Compose
it ships, which is newer than 5.5.0, and Compose 5.5.0 changed the image
identity it records on each container: an older Compose sees a container
created by a newer one as out of date, and its next `up -d` recreates it on
the same image. Nothing unverified is deployed, but the resolver restarts.
The classic image store is not affected.

## The Docker socket is root on the host

The sidecar mounts `/var/run/docker.sock`. Whoever can use that socket can
start a privileged container and control the host, so the sidecar is a
root-equivalent component, and runs as root. Through the socket it:

- reads containers, images and Compose labels (`docker ps`, `docker inspect`,
  `docker image inspect`, `docker info`);
- resolves tags to digests when the registry cannot be asked directly
  (Engine API distribution endpoint), pulls by
  digest, tags images (the operator's tag at a swap or rollback, the
  `autoupdate-<project>-<service>` keep names) and removes the digest references it pulled;
- runs `docker compose config`, `ps` and `up` on its own project;
- runs containers: `unbound-checkconf`, the copy of the state volume, the
  canary (with its network and volume), and the self-update helper;
- runs `unbound-control` in the resolver (`docker exec`: statistics at every
  scrape, cache export and import around a swap) and copies its
  `/var/lib/unbound/root.key` out at every scrape (`docker cp`).

A socket proxy that allows these calls allows creating containers with
arbitrary mounts, so it does not reduce what the sidecar can do. Not using the
sidecar: [Updating without the sidecar](../docs/usage.md#updating-without-the-sidecar).

## Install

The sidecar joins the resolver's own Compose project: it only ever manages
services of the project its own container belongs to. From the directory of
the project started in the README's [Run it](../README.md#run-it) section:

<!-- sidecar:install — tests/sidecar-docs.sh runs the first line and validates the resulting project -->
```bash
curl -fsSL https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/updater/compose.snippet.yml | sed "s|/opt/unbound|$PWD|g" > docker-compose.override.yml
docker compose up -d
docker compose logs unbound-autoupdate
```

Without `-f`, `docker compose` reads `docker-compose.override.yml` together
with `docker-compose.yml`, so the project now has two more services: the
update loop (`unbound-autoupdate`) and the `/metrics` endpoint
(`unbound-metrics`, on `127.0.0.1:9167`). The `sed` writes the project's
absolute path on both sides of the bind mount (next section). A command that
names its files with `-f` must name both:
`docker compose -f docker-compose.yml -f docker-compose.override.yml …`.
To be alerted, uncomment `HC_URL` (or set `WEBHOOK_URL`) in
`docker-compose.override.yml` and run `docker compose up -d` again.

Requirements on the resolver service: a **named volume on
`/var/lib/unbound`** (the canary runs on a copy of it), and an image pulled
from a registry, which carries a repository digest; a locally built resolver
image is refused.

A two-host deployment with alerts and runbooks:
[docs/production.md](../docs/production.md).

## The same-absolute-path rule

The sidecar runs `docker compose` itself, against your project's real files,
with the file list Compose stamped on the resolver container. Those paths are
host paths. Compose then resolves the project's relative bind mounts against
the project directory, and the Docker daemon applies them on the host — so a
path that means one thing inside the sidecar and another on the host would
quietly deploy the wrong files.

That is why the project directory is mounted read-only inside the sidecar at
the same absolute path it has on the host (`/opt/unbound:/opt/unbound:ro`),
and why every declared bind-mount source must be reachable under that path
too. Get it wrong and the cycle stops immediately with:

```
compose file '/opt/unbound/docker-compose.yml' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path
```

## Validate without deploying

```bash
docker compose run --rm unbound-autoupdate check
```

Runs a cycle up to the end of the canary (steps 1 to 12) and stops before the
swap, even when nothing changed. Exit 0: the declared image and configuration
passed on a copy of production's state. Exit 1: a check refused them, or the
cycle failed before judging (the log says which). Exit 2: not evaluated
(another cycle holds the lock, a quarantine, or a refused major version). The
run is recorded like any cycle: Healthchecks pings, `state.env` counters and
metrics.

## Variables

The sidecar's configuration is its environment. `tests/sidecar-docs.sh`
checks that this table lists exactly the variables the code reads, with the
code's defaults. Durations accept `45s`, `30m`, `1h`, `2d` or a number of
seconds.

| Variable | Default | Meaning |
|---|---|---|
| `RUN_MODE` | `loop` | `loop`, `once`, `check`, `metrics` or `idle` (no cycle; for `docker compose exec`). A command argument (`command: ["metrics"]`) takes precedence. |
| `INTERVAL` | `1h` | Time between cycles in `loop` mode; the first cycle runs at start. |
| `SPLAY` | `10%` | Random delay of up to this much added to each `INTERVAL`: a percentage of it, or a duration. |
| `WATCH_CONFIG` | `1` | `0`: a change of the declared bind-mounted files alone does not start a canary and a redeploy. |
| `TARGET_SERVICE` | auto | The resolver service. Unset: the one running service of the project whose image reference contains `unbound` and whose repository is not the sidecar's own; with two or more, the cycle stops and asks for this variable. |
| `ALLOW_MAJOR` | `0` | `1`: accept a new major version of the resolver and of the sidecar. |
| `ALLOW_DOWNGRADE` | `0` | `1`: accept a resolver or sidecar image whose version label is older than the running one. |
| `RETRY_AFTER` | `24h` | How long a failed image, configuration or sidecar image is not retried. |
| `VALIDATE_DOMAIN` | `example.com` | Name resolved (UDP and TCP) to judge a resolver. |
| `REQUIRE_DNSSEC` | `1` | `0`: do not require the AD flag on the root SOA (a resolver deliberately run without the validator). |
| `STRICT_BOGUS_CHECK` | `0` | `1`: also require `dnssec-failed.org` to fail with SERVFAIL. |
| `HC_URL` | unset | Healthchecks.io check URL: `/start` at the start of a cycle, then the URL itself on success or `/fail`. |
| `WEBHOOK_URL` | unset | Receives each notification as a JSON POST with `event`, `host`, `subject`, `body` and `text`. |
| `NOTIFY_HOST` | unset | Host name in notifications. Unset: the Docker daemon's host name, else the container's. |
| `SELF_UPDATE` | `1` | `0`: the sidecar never replaces itself. See [Self-update](#self-update). |
| `SELF_LOCK_WAIT` | `900` | Seconds the self-update helper waits for the cycle lock (before recreating the sidecar, and before writing state) before going ahead without it. |
| `COSIGN_PUBLIC_KEY` | unset | Path, inside the container, of a PEM public key: key mode instead of keyless. See [Verifying with your own key](#verifying-with-your-own-key). |
| `COSIGN_RESOLVER_IDENTITY_REGEXP` | `^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$` | Keyless mode: the certificate identity that must have signed a resolver image. |
| `COSIGN_SIDECAR_IDENTITY_REGEXP` | `^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/updater\.yml@refs/tags/updater-v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$` | Keyless mode: the certificate identity that must have signed a sidecar image. |
| `COSIGN_IDENTITY_REGEXP` | unset | Keyless mode: when set, used for both kinds of image instead of the two above. |
| `COSIGN_ISSUER` | `https://token.actions.githubusercontent.com` | Keyless mode: the OIDC issuer of the signing certificate. |
| `COSIGN_IGNORE_TLOG` | `0` | Key mode: `1` accepts a signature that is not in the public Rekor log. |
| `METRICS_PORT` | `9167` | Port of `/metrics` in `metrics` mode. |
| `STATE_DIR` | `/var/lib/unbound-autoupdate` | Directory of the state files. Must survive the container: a named volume. |
| `DOCKER_CONFIG` | unset | Directory of a Docker client `config.json` whose static `auths` entries are used for the registry (default `$HOME/.docker`). Credential helpers are not supported. |
| `SIGSTORE_ROOT_FILE` | unset | cosign's own variable (`cosign env --show-descriptions`): Fulcio root CA file. Its content is part of the verification settings ([State](#state)). |
| `SIGSTORE_REKOR_PUBLIC_KEY` | unset | cosign's own variable: Rekor public key file. Same remark. |
| `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE` | unset | cosign's own variable: CT log public key file. Same remark. |
| `SIGSTORE_TSA_CERTIFICATE_FILE` | unset | cosign's own variable: TSA certificate chain file. Same remark. |
| `CHECK_ONLY` | `0` | `1`: validate without swapping. Set by `check` mode. |
| `DISCOVER_WAIT` | `60` | Seconds a cycle waits for the resolver container when none is running (a recreation in progress). A `/metrics` scrape does not wait. |
| `FINGERPRINT_EXCLUDE` | unset | Container paths, space-separated, whose files are left out of configuration change detection (data that another tool updates and loads at run time, such as a blocklist). They are still mounted in the canary. |
| `KEEP_CACHE` | `1` | Carry the resolver's cache over a swap (`dump_cache` before, `load_cache` after the new container has passed its checks). Not done when the Unbound major.minor version changes or an image has no version label. Only unexpired entries are exported. `0` disables it. |
| `KEEP_CACHE_MAX_ENTRIES` | `500000` | Above this many record sets, the cache is not exported. |
| `KEEP_CACHE_CHUNK` | `2000` | Entries per `load_cache` batch. |
| `KEEP_CACHE_TIMEOUT` | `120` | Seconds allowed to the export, and to the whole import. |

## Behaviour

How each cycle ends. "Metric status" is the `status` label set to 1 in
`unbound_autoupdate_last_cycle_status`, and incremented in
`unbound_autoupdate_cycles_total`. Every cycle that takes the lock sends
`/start` to `HC_URL` first; the column shows the final ping. A notification
is a log line `level=notice event=<event> subject="<subject>"` and, with
`WEBHOOK_URL`, a POST.

| Outcome | Exit | Final ping | Notification `event`: subject | Metric status |
|---|---|---|---|---|
| Another cycle holds the lock | 2 | none (no `/start` either) | none | unchanged |
| First cycle on a host (then continues) | — | — | `baseline`: baseline recorded | — |
| Nothing changed | 0 | success | none | `up_to_date` |
| `check` mode, everything passed | 0 | success | none | `check_ok` |
| Updated and checked | 0 | success | `updated`: updated successfully | `updated` |
| Pull failed (`pulling the declared image failed` in the log) | 1 | `/fail` pull failed | none | `blocked` |
| Configuration fingerprint failed | 1 | `/fail` config fingerprint failed | none | `blocked` |
| Signature refused (new image, or the running one) | 1 | `/fail` signature verification failed | `blocked`: signature verification FAILED | `blocked` |
| Signature could not be checked: a network or registry error only (connection failure, timeout, rate limit, HTTP 5xx); any sign that a signature was evaluated counts as refused | 1 | `/fail` signature check unavailable | `blocked`: signature could not be checked | `blocked` |
| Quarantined image or configuration | 2 | `/fail` | `skipped`: update skipped (quarantine) | `skipped` |
| Major version refused | 2 | `/fail` major bump refused | `skipped`: major version bump not deployed | `skipped` |
| Older version refused (after verification) | 2 | `/fail` downgrade refused | `skipped`: downgrade not deployed | `skipped` |
| Host-networked sidecar with a change | 1 | `/fail` canary start failed | `blocked`: canary could not start | `blocked` |
| Preflight rejected the configuration | 1 | `/fail` preflight failed | `blocked`: configuration rejected in preflight | `blocked` |
| Canary did not start | 1 | `/fail` canary start failed | `blocked`: canary could not start | `blocked` |
| Canary failed the validation | 1 | `/fail` canary validation failed | `blocked`: canary rejected the update | `blocked` |
| Post-swap checks failed, rollback succeeded | 1 | `/fail` post-swap validation failed | `rollback`: ROLLBACK performed | `rollback` |
| Post-swap checks failed, rollback failed | 1 | `/fail` post-swap validation failed | `critical`: CRITICAL: rollback failed | `critical` |
| Any other failure (discovery, unreadable compose file, SIGTERM outside a swap) | non-zero | none after `/start` | none | `error` |

In every row before the swap, production is not touched and the operator's
tag does not move.
After a refused signature or one that could not be checked, self-update is
still attempted, and the cycle ends `blocked` whatever it does. A rollback
that fails leaves `SWAP_INTENT` set, so the next cycle tries once more; if
that also fails, the intent is cleared and the resolver is left as it is
found. After a recovered interrupted swap, the `updated` notification says
so.

Self-update, at the end of an `up_to_date` or `updated` cycle:

| Outcome | Cycle exit | Notification | Effect on the cycle |
|---|---|---|---|
| Skipped (`SELF_UPDATE=0`, a helper still running, a compose file unreadable, the declared image unchanged or not resolvable, a quarantine, no state volume found) | unchanged | none (log line) | none |
| Major version refused | unchanged | `skipped`: sidecar major version bump not applied | none |
| Older version refused (after verification) | unchanged | `skipped`: sidecar downgrade not applied | none |
| Signature refused | 1 | `blocked`: sidecar signature verification FAILED | `blocked`, `/fail` sidecar self-update refused |
| Signature could not be checked | 1 | `blocked`: sidecar signature could not be checked | same |
| Helper could not start | 1 | `blocked`: sidecar self-update could not start | same |
| Helper started | unchanged | none | none |

The helper's own outcomes (it is not a cycle: it sends no `/start` and no
success ping):

| Outcome | Helper exit | Notification | Ping |
|---|---|---|---|
| Sidecar services replaced and running | 0 | `updated`: sidecar updated | none |
| Failed, previous image back | 1 | `critical`: sidecar self-update FAILED — rolled back | `/fail` self-update failed |
| Failed, rollback failed too | 1 | `critical`: CRITICAL: sidecar self-update FAILED and rollback failed | `/fail` self-update failed |

## Self-update

With `SELF_UPDATE=1` (the default), after a cycle that ended `up_to_date` or
`updated`, and when no helper from an earlier cycle is still running:

1. The image declared for the sidecar's own service is read from the compose
   files the sidecar's own container was created from. An override file that
   pins the sidecar is therefore taken into account.
2. That tag is resolved to its registry digest and pulled by digest, as for
   the resolver. Same image ID as the running sidecar: nothing to do.
3. The self quarantine (`RETRY_AFTER`) and the major-version rule apply,
   then cosign verification against the sidecar's identity, then the
   downgrade rule. There is no canary.
4. A helper container is started from the new image, labelled
   `unbound-autoupdate.helper=1`, removed when it exits. It first waits for
   the cycle that launched it to end (the cycle lock is free), since that
   cycle still records its outcome inside the container about to be
   replaced. It then points the
   operator's sidecar tag at the new image and recreates the sidecar's own
   service with `--pull never`; that container must be new, run the new
   image, and still be running without restart 30 s later. Only then are the
   other services declared on the same image (`unbound-metrics`) recreated
   and checked the same way, without the 30 s wait.
5. On failure the helper points the tag back at the previous image (or, for a
   sidecar declared by digest, writes `self-rollback.yml` naming
   its keep name), recreates the services it moved,
   checks they run the previous image, and quarantines the new one.

Both waits for the cycle lock, before recreating the sidecar and before the
helper writes `state.env`, last at most `SELF_LOCK_WAIT` seconds; when it runs
out the helper logs an error and goes ahead without the lock.

## State

`STATE_DIR` (a named volume) holds:

| File | Content |
|---|---|
| `state.env` | The keys below, `KEY=value` per line |
| `metrics.prom` | The sidecar's metrics, rewritten at the end of each cycle and by the self-update helper |
| `lock` | The cycle lock |
| `rollback.yml`, `self-rollback.yml` | Written by a rollback of a service declared by digest or by another repository; used for that `compose up` only, and ignored when found in a compose file list |

| Key | Meaning |
|---|---|
| `LAST_CONFIG_HASH` | Configuration fingerprint at the baseline, then at each successful update |
| `LAST_IMAGE_DIGEST` | Image running at the baseline, then deployed at each successful update. Not read by the code |
| `VERIFIED_DIGEST`, `VERIFIED_POLICY` | The last image that passed verification, and a hash of the settings it passed under: mode, identity, issuer, key content, `COSIGN_IGNORE_TLOG`, every `COSIGN_*`, `SIGSTORE_*` and `TUF_ROOT` variable, and the content of the `SIGSTORE_*` files. A change of either verifies again |
| `QUARANTINE_DIGEST`, `QUARANTINE_TS` | Quarantined resolver image, and when |
| `CONFIG_QUARANTINE_HASH`, `CONFIG_QUARANTINE_TS` | Quarantined configuration fingerprint, and when |
| `SELF_QUARANTINE_DIGEST`, `SELF_QUARANTINE_TS` | Quarantined sidecar image, and when |
| `SWAP_INTENT` | Set while a swap or rollback is in progress, nine fields: new image, its ID, previous image ID, fingerprint, image changed (0/1), configuration changed (0/1), previous repository, container before the swap, image the declared tag named before the swap (`-` for none). Empty otherwise |
| `PULLED_REFS` | Digest references the sidecar pulled because they were not present. At the end of a cycle that reaches up to date, updated or rolled back, each one other than the declared image is removed from the local image store, once no tag names its image and neither the resolver nor the sidecar runs it |
| `LAST_CYCLE_STATUS`, `LAST_CYCLE_TS`, `LAST_CYCLE_DURATION`, `CYCLES_<STATUS>` | The last cycle and the per-outcome counters |
| `SELF_UPDATE_TS` | Last successful self-update |

A quarantine is active while its value equals the value being considered and
`RETRY_AFTER` has not elapsed since its timestamp. Emptying both keys of an
axis lifts it.

Local images: `<repository>:autoupdate-<project>-<service>` (characters
outside `A-Za-z0-9_.-` replaced by `-`) names what each service runs, and the digest references in `PULLED_REFS` are untagged
records.

## Metrics

`metrics` mode serves `/metrics` on `METRICS_PORT` with busybox `httpd`. Every
scrape answers 200, within about 15 s, with:

- **Resolver statistics**: `unbound-control stats_noreset`, run in the
  resolver container, converted by `stats_to_prometheus`
  (`updater/lib/metrics.sh`): `total.num.*` keys become
  `unbound_<name>_total` counters and other `total.*` keys gauges; per-thread
  keys become `unbound_thread_*{thread}`; `num.query.type|class|opcode|flags|aggressive.*`
  and `num.answer.rcode.*` become labelled counters
  (`unbound_query_types_total{type}`, `unbound_answer_rcodes_total{rcode}`, …);
  `num.answer.secure|bogus` and `num.rrset.bogus` become
  `unbound_answers_secure_total`, `unbound_answers_bogus_total`,
  `unbound_rrset_bogus_total`; `mem.*` become `unbound_mem_*_bytes`;
  `*.cache.count` become `unbound_cache_entries{cache}`; `time.now|up|elapsed`
  become `unbound_time_*_seconds`; the recursion time average and median
  become `unbound_recursion_time_seconds{stat}`; the queue-time maximum
  becomes `unbound_query_queue_time_seconds{stat="max"}` (and per thread);
  the histogram becomes `unbound_response_time_seconds` with
  `unbound_response_time_percentile_seconds{percentile="50|95|99"}`; any
  other key becomes `unbound_stat{name}`.
- **Trust anchor**, from the resolver's `/var/lib/unbound/root.key`:
  `unbound_trust_anchor_last_success_timestamp_seconds`,
  `unbound_trust_anchor_next_probe_timestamp_seconds`,
  `unbound_trust_anchor_failed_probes`, and
  `unbound_trust_anchor_key_info{keytag,state}` per root KSK.
- **The sidecar**, from `metrics.prom`: `unbound_autoupdate_info{version,image_digest}`,
  `unbound_autoupdate_last_cycle_timestamp_seconds`,
  `unbound_autoupdate_last_cycle_duration_seconds`,
  `unbound_autoupdate_last_cycle_status{status}` (one-hot over `up_to_date`,
  `updated`, `check_ok`, `skipped`, `blocked`, `rollback`, `critical`,
  `error`), `unbound_autoupdate_cycles_total{status}`,
  `unbound_autoupdate_quarantine_active{axis="image|config|self"}`,
  `unbound_autoupdate_target_image_info{digest,version}` (from
  `LAST_IMAGE_DIGEST`) and
  `unbound_autoupdate_self_update_last_timestamp_seconds` (0: never).
  These change only when the file is rewritten: a quarantine series stays 1
  after `RETRY_AFTER` until the next cycle ends.
- **The scrape**: `unbound_exporter_scrape_success` (0 when the statistics
  could not be collected) and `unbound_exporter_scrape_duration_seconds`.

The output passes `promtool check metrics` (`tests/updater.sh`,
`tests/observability.sh`). Scrape configuration and alert rules:
[docs/observability/](../docs/observability/). Publish the port on loopback
or a monitoring network only: the endpoint uses the Docker socket.

## Verifying with your own key

Keyless verification is the default: the resolver must be signed by
`release.yml` on a `vX.Y.Z-rN` tag of this repository, the sidecar by
`updater.yml` on an `updater-vX.Y.Z-rN` tag (`COSIGN_RESOLVER_IDENTITY_REGEXP`,
`COSIGN_SIDECAR_IDENTITY_REGEXP`; `COSIGN_IDENTITY_REGEXP`, when set,
replaces both). For a private mirror that re-signs what it serves, mount its
public key and point `COSIGN_PUBLIC_KEY` at it:

```yaml
    environment:
      COSIGN_PUBLIC_KEY: /keys/mirror.pub
      COSIGN_IGNORE_TLOG: "1"   # only if the mirror's signatures are not in Rekor
    volumes:
      - /etc/unbound-keys/mirror.pub:/keys/mirror.pub:ro
```

With a key, the identity and issuer variables are not used. An unreadable
key file is a refusal. The same key verifies the sidecar's own image: the
mirror must re-sign `unbound-autoupdate` too, or set `SELF_UPDATE=0`.

The image carries the cosign v3.1.3 CLI (pinned by digest in
`.build-state.json`); the release workflows sign with cosign v2.6.5.
`tests/updater.sh` verifies the published releases with it, keyless, and a
key-signed image in key mode. Verifying by hand:
[docs/trust.md](../docs/trust.md#verifying-releases).

## What it does not do

- **Kubernetes, or containers outside its own Compose project.** Discovery
  starts from the sidecar's `com.docker.compose.project` label.
- **Canary with `network_mode: host`.** A host-networked container cannot
  join another network; a host-networked sidecar (which a host-networked
  resolver requires, to be probed) refuses every cycle that has a change.
- **Revert configuration files.** A rollback restores the image only; the
  notification says when the configuration changed.
- **Registry credential helpers.** Only static `auths` entries of
  `DOCKER_CONFIG/config.json` are used.
- **Roll back without a local copy of the previous image.** A rollback uses
  the local record kept under its keep name; if that record and the tag
  were already gone before the first cycle of this version could name them
  (a warning is logged), only the registry can bring the image back.
- **Survive a kill mid-swap within the same cycle.** If the container is
  killed during a swap (longer than its stop grace period), the resolver may
  be stopped until the next cycle finishes or reverts the swap; if that
  recovery fails, it is abandoned and a person has to act.
- **Prevent a manual redeploy.** `docker compose pull` followed by `up -d`,
  or `pull_policy: always` on the sidecar's services, deploys what the
  registry serves under the tag without these checks.
- **Dashboards.** Plain Prometheus exposition.

## Upgrading from the removed host-side updater

This repository used to ship a host-side `unbound-autoupdate` script run by a
systemd timer. It pulled `esitcparis/unbound-distroless:1`, then ran
`docker compose up -d`, which deploys the tag the compose file declares
without pulling it; this repository's compose file declared `:latest` at the
time. Unless your compose file declared `:1`, a resolver it reported as
updated stayed on its old image. Remove it (*not run* here: systemd host
commands):

```bash
systemctl disable --now unbound-autoupdate.timer
rm -f /usr/local/bin/unbound-autoupdate /etc/systemd/system/unbound-autoupdate.service /etc/systemd/system/unbound-autoupdate.timer /etc/unbound-autoupdate.conf
systemctl daemon-reload
```

Then install the sidecar ([Install](#install)), or update by hand
([Updating without the sidecar](../docs/usage.md#updating-without-the-sidecar)).
