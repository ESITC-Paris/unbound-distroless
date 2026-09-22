# unbound-autoupdate

A Compose-native sidecar that keeps a Docker Compose resolver on the current
`unbound-distroless` image — and proves the new image works, with your
configuration, before production ever sees it. The same image also serves a
Prometheus `/metrics` endpoint for the resolver and for the updater itself.

## What it does

One cycle, every `INTERVAL`:

1. **Discover** — finds the resolver service in its own Compose project from
   the container labels (or `TARGET_SERVICE`), reads the project's declared
   state with `docker compose config`, and the running state with
   `docker inspect`. Those two are kept apart on purpose: the canary must test
   what Compose *will* deploy, not what happens to be mounted right now.
2. **Compare image and configuration** — `docker compose pull` on the service,
   then the declared repository digest against the running one. Independently,
   a SHA-256 fingerprint over *every* declared bind mount (not just
   `unbound.conf`: a rotated certificate is a change too) against the one
   recorded at the last successful cycle. A mount that is a directory is
   expanded to the files beneath it **with symlinks followed**, so a `tls/`
   directory in the Let's Encrypt `live/` layout is covered like any other;
   a dangling symlink, or a directory mount that expands to no file at all,
   fails the cycle loudly rather than quietly contributing nothing. Nothing
   changed and nothing is due: the cycle ends there.
3. **Quarantine** — an image digest or a configuration fingerprint that
   already failed a deployment is not retried before `RETRY_AFTER`. The two
   are separate axes, so a bad configuration does not hold back a good image,
   and a different digest or an edited file always gets a fresh attempt.
4. **Major guard, then cosign** — a change of major Unbound version (read from
   the images' `org.opencontainers.image.version` labels) is refused unless
   `ALLOW_MAJOR=1` — if either image carries no version label the guard is
   skipped, with a warning. Then the new image's signature is verified with
   `cosign`,
   fail-closed: an unverified image is never run, not even as a canary.
5. **Preflight** — the new image's own `unbound-checkconf` runs against the
   declared configuration. This is what turns "the canary never came up" into
   an error message naming the offending directive or file.
6. **Canary on cloned state** — the new image starts on an isolated bridge
   network, with the declared bind mounts, the declared runtime settings
   (`read_only`, `tmpfs`, `environment`, `ulimits`, `sysctls`) and a **copy**
   of production's `/var/lib/unbound` volume. It must answer `VALIDATE_DOMAIN`
   over UDP and over TCP, and — unless `REQUIRE_DNSSEC=0` — return the AD flag
   on the root SOA. Production keeps serving throughout and is not touched.
7. **Swap** — `docker compose up -d --no-deps` on the one service (with
   `--force-recreate` when only the configuration changed, because Compose
   keys recreation on the service definition, which the *contents* of a
   bind-mounted file do not affect).
8. **Post-swap gate, then rollback** — Compose exiting 0 is not proof: the
   container id must have changed, the running digest must now be the declared
   one, and the resolver must pass the *same* validation the canary passed. If
   any of that fails, an override pins the previous digest back, production is
   revalidated, the failing change is quarantined, and you are notified.

So the new image is validated with **your** configuration and a clone of
**your** state before anything is deployed.

## The Docker socket is root on the host

The sidecar mounts `/var/run/docker.sock`. Anyone who can write to that socket
can start a privileged container and own the host, so this is a real decision,
not a formality — but **no container-based updater can do without it**: pulling
an image, running a canary and recreating a service are all Docker API calls.

What this sidecar does with the socket:

- `docker inspect` / `docker ps` on its own container and its project's, to
  discover the resolver and read the Compose labels;
- `docker compose pull` and `docker compose config` on the project;
- `docker run --rm` for the `unbound-checkconf` preflight and for the state
  clone, and `docker run -d` for the canary, plus the `docker network` and
  `docker volume` create/remove that the canary needs;
- `docker compose up -d --no-deps` on the one resolver service — the swap,
  and the rollback;
- `docker exec … unbound-control stats_noreset` in the resolver, in metrics
  mode only;
- `docker run -d` of an ephemeral helper from the new sidecar image when it
  updates itself (see [Self-update](#self-update)).

If you run something like `tecnativa/docker-socket-proxy`, the sidecar needs
`POST=1` plus `CONTAINERS`, `IMAGES`, `NETWORKS`, `VOLUMES`, `EXEC` and
`INFO`. That set allows creating and starting arbitrary containers with
arbitrary mounts, so the proxy buys you very little here: treat the sidecar as
a root-equivalent component on the host either way, and keep the rest of the
project's attack surface small instead.

## Install

Add both services to the resolver's own Compose project — the sidecar only
ever manages services that carry its own `com.docker.compose.project` label.
This is [`compose.snippet.yml`](compose.snippet.yml):

```yaml
  unbound-autoupdate:
    image: esitcparis/unbound-autoupdate:1
    restart: unless-stopped
    environment:
      INTERVAL: 1h
      # One Healthchecks.io check per host. The updater pings /start, success
      # and /fail, so every failure alerts immediately.
      HC_URL: https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      # NOTIFY_HOST: resolver-1.example   # defaults to the Docker daemon's host name
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/unbound:/opt/unbound:ro
      - autoupdate-state:/var/lib/unbound-autoupdate

  unbound-metrics:
    image: esitcparis/unbound-autoupdate:1
    command: ["metrics"]
    restart: unless-stopped
    ports:
      - "127.0.0.1:9167:9167"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - autoupdate-state:/var/lib/unbound-autoupdate:ro

volumes:
  autoupdate-state:
```

Replace `/opt/unbound` with the absolute path of *this* project's directory on
both sides of the mount, then:

```bash
docker compose up -d
docker compose logs -f unbound-autoupdate
```

The first cycle records a baseline instead of canarying a resolver that is
already running fine:

```
ts=2026-09-16T10:00:00Z level=info msg="unbound-autoupdate 1.0.0-r0 starting: interval=1h splay=10%"
ts=2026-09-16T10:00:04Z level=info msg="baseline recorded (image esitcparis/unbound-distroless@sha256:…)"
ts=2026-09-16T10:00:04Z level=notice event=baseline subject="baseline recorded"
```

The resolver service must have a **named volume on `/var/lib/unbound`** (the
DNSSEC trust anchor lives there, and it is what the canary clones) and must
declare an image that carries a repository digest — a locally built image is
refused rather than guessed at.

For a full two-host production deployment — host prerequisites, a hardened
Compose reference that was brought up and validated before being written down,
Prometheus alerts and a runbook per failure mode — see
[`../docs/production.md`](../docs/production.md).

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

`check` mode runs the whole cycle — pull, compare, cosign, preflight, canary,
DNS validation — and stops before the swap. Use it after editing
`unbound.conf`, or to see what the next cycle would do:

```bash
docker compose run --rm unbound-autoupdate check
```

Exit 0 means the declared image and configuration passed everything on a
canary with a clone of production state; production was not touched.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `RUN_MODE` | `loop` | `loop`, `once`, `check`, `metrics` or `idle`. Overridden by a command argument (`command: ["metrics"]`). |
| `INTERVAL` | `1h` | Time between cycles in `loop` mode. `45s`, `30m`, `1h`, `2d` or bare seconds. |
| `SPLAY` | `10%` | Random jitter added to `INTERVAL`, as a percentage of it or an absolute duration, so a fleet never updates in the same minute. |
| `WATCH_CONFIG` | `1` | Also treat a change in the declared bind mounts as an update to canary and deploy. |
| `TARGET_SERVICE` | auto | The resolver service. Discovery picks the one sibling service in the project whose image repository mentions `unbound`; set this when there are several. |
| `ALLOW_MAJOR` | `0` | Accept a major version bump (resolver **and** sidecar) instead of refusing it. |
| `RETRY_AFTER` | `24h` | How long a failed image, configuration or sidecar image stays quarantined. |
| `VALIDATE_DOMAIN` | `example.com` | Domain queried to decide a resolver is healthy. |
| `REQUIRE_DNSSEC` | `1` | Require the AD flag on the root SOA. Set to `0` only for a resolver deliberately run without the validator (a forwarder to an unsigned internal upstream). |
| `STRICT_BOGUS_CHECK` | `0` | Also require `dnssec-failed.org` to SERVFAIL. Needs working external DNS from the canary. |
| `HC_URL` | unset | Healthchecks.io check URL. The cycle pings `/start`, then the plain URL on success or `/fail` on failure. |
| `WEBHOOK_URL` | unset | JSON webhook for notifications (`event`, `host`, `subject`, `body`, `text`). |
| `NOTIFY_HOST` | Docker daemon host name | Host name notifications are attributed to. Falls back to the daemon's name, then the container's. |
| `SELF_UPDATE` | `1` | Let the sidecar update itself. See [Self-update](#self-update). |
| `SELF_LOCK_WAIT` | `900` | Seconds the self-update helper waits for the cycle lock before writing state anyway (loudly). A live cycle legitimately holds it for minutes. |
| `COSIGN_PUBLIC_KEY` | unset | Path to a PEM public key. Unset means keyless verification. |
| `COSIGN_IDENTITY_REGEXP` | `https://github.com/ESITC-Paris/unbound-distroless/.*` | Keyless mode: the certificate identity that must have signed the image. |
| `COSIGN_ISSUER` | `https://token.actions.githubusercontent.com` | Keyless mode: the OIDC issuer. |
| `COSIGN_IGNORE_TLOG` | `0` | Key mode only: accept a signature that is not in the public Rekor log. |
| `METRICS_PORT` | `9167` | Port `metrics` mode listens on. |
| `STATE_DIR` | `/var/lib/unbound-autoupdate` | Where `state.env` and `metrics.prom` live. Must be writable and survive container recreation — a named volume, or a bind mount. |
| `CHECK_ONLY` | `0` | Validate but never swap. `check` mode sets it; you rarely set it by hand. |
| `DISCOVER_WAIT` | `60` | Seconds a cycle waits for the resolver container when it is absent — the window where `docker compose up` has removed the old one and not yet started the new one. The metrics scrape leaves this at `0` and fails fast. |
| `FINGERPRINT_EXCLUDE` | *(empty)* | Container paths (space-separated) removed from configuration CHANGE DETECTION — for data another tool manages and applies at runtime, typically a blocklist loaded with `unbound-control local_zones`. Without it every regeneration is a canary and a container swap, which restarts unbound and empties its cache. The mount is still given to the canary, so image updates are validated against the real data. The owning tool must validate the data itself. |
| `KEEP_CACHE` | `1` | Carry the resolver cache over a swap: exported from the outgoing container (`dump_cache`) just before it, imported into the new one (`load_cache`) only after the new one has passed its post-swap validation, and into the previous one after a rollback. Only entries still valid at export time travel: unbound's export skips expired ones, so entries kept for serve-expired are lost and must be re-learned (a host-side warm-up helps). Skipped when the unbound major.minor version changes. Best effort: a failure only means starting with an empty cache, never a failed update. `0` disables it. |
| `KEEP_CACHE_MAX_ENTRIES` | `500000` | Record sets above which the cache is not exported. The export holds one worker thread of the outgoing resolver (measured: 0.8 s per 100 000 entries). |
| `KEEP_CACHE_CHUNK` | `2000` | Entries per `load_cache` batch. One 100 000-entry import held a worker thread for 4.7 s; batches of 5 000 kept every answer under 140 ms. |
| `KEEP_CACHE_TIMEOUT` | `120` | Seconds allowed to the export, and to the import as a whole; what is loaded by then stays. |

## Behaviour

Every cycle ends in exactly one of these. "Metric status" is the label that
goes to 1 in `unbound_autoupdate_last_cycle_status`; its
`unbound_autoupdate_cycles_total{status=…}` counter is incremented at the same
time.

| Situation | Exit code | Healthchecks | Notification event | Metric status |
|---|---|---|---|---|
| Nothing new | 0 | `/start`, success | — | `up_to_date` |
| First cycle on a host (baseline recorded; the cycle then continues) | the cycle's own | `/start`, then the cycle's own | `baseline` | the cycle's own |
| `check` mode, everything validated | 0 | `/start`, success | — | `check_ok` |
| Pull or config fingerprint failed | 1 | `/start`, `/fail` | — | `blocked` |
| Unsigned image (cosign refused it) | 1 | `/start`, `/fail` | `blocked` | `blocked` |
| Preflight (`unbound-checkconf`) rejected the configuration | 1 | `/start`, `/fail` | `blocked` | `blocked` |
| Canary could not start, or failed DNS validation | 1 | `/start`, `/fail` | `blocked` | `blocked` |
| Quarantined image or configuration | 2 | `/start`, `/fail` | `skipped` | `skipped` |
| Major version bump refused | 2 | `/start`, `/fail` | `skipped` | `skipped` |
| Another cycle is already running | 2 | — (no ping) | — | unchanged |
| Swap OK, post-swap gate passed | 0 | `/start`, success | `updated` | `updated` |
| Swap failed → rolled back, resolver healthy | 1 | `/start`, `/fail` | `rollback` | `rollback` |
| Rollback did not restore a working resolver | 1 | `/start`, `/fail` | `critical` | `critical` |
| Unexpected death (a `log_die`, an unhandled error) | non-zero | `/start`, no final ping | — | `error` |

The last row is why the `/start` ping matters: the cycle records itself as
`error` on the way out, and Healthchecks alerts on its own grace timer because
the run it was told about never finished.

Sidecar self-update happens at the *end* of an `up_to_date` or `updated`
cycle, never after a failure and never in `check` mode:

| Situation | Exit code | Healthchecks | Notification event | Metric status |
|---|---|---|---|---|
| Nothing to do, a helper is still running, locally built image, no state volume, pull or `compose config` failed, or the sidecar image is quarantined | 0 | `/start`, success | — (log line only) | the cycle's own (`up_to_date` / `updated`) |
| Sidecar major version bump refused | 0 | `/start`, success | `skipped` | the cycle's own |
| Sidecar image failed cosign verification | 1 | `/start`, `/fail` | `blocked` | `blocked` |
| The helper container could not be started | 1 | `/start`, `/fail` | `blocked` | `blocked` |
| Helper launched | 0 | `/start`, success | — | the cycle's own |
| Helper: sidecar replaced and healthy | 0 (helper) | — | `updated` | unchanged; `…_self_update_last_timestamp_seconds` is set |
| Helper: new sidecar did not come up, rolled back | 1 (helper) | `/fail` | `critical` | unchanged; `…_quarantine_active{axis="self"}` goes to 1 |
| Helper: neither image could be brought up | 1 (helper) | `/fail` | `critical` | unchanged; `…_quarantine_active{axis="self"}` goes to 1 |

## Metrics and alerts

In `metrics` mode the image serves `/metrics` on port `METRICS_PORT` (9167).
Publish it on a loopback address, or on a private network — it needs the
Docker socket, so do not expose it publicly.

One endpoint, three sources:

- **the resolver**, converted from `unbound-control stats_noreset` executed in
  the resolver container on each scrape;
- **the updater**, read from `metrics.prom` in the shared state volume, which
  every cycle rewrites;
- **the scrape itself**, so a resolver that cannot be reached is still visible
  rather than being a hole in the data.

The scrape never fails: it answers 200 even when `unbound-control` is
unreachable, and reports that with `unbound_exporter_scrape_success 0`.

```
unbound_queries_total 2468
unbound_cachehits_total 1800
unbound_thread_queries_total{thread="0"} 1234
unbound_query_types_total{type="AAAA"} 800
unbound_answer_rcodes_total{rcode="SERVFAIL"} 12
unbound_answers_secure_total 2100
unbound_cache_entries{cache="rrset"} 9876
unbound_recursion_time_seconds{stat="median"} 0.098304
unbound_query_queue_time_seconds{stat="max"} 0.012500
unbound_response_time_seconds_bucket{le="0.000512"} 3
unbound_mem_cache_rrset_bytes 178860
unbound_time_up_seconds 86400.000000
unbound_stat{name="num.query.tcpout"} 44

unbound_autoupdate_info{version="1.0.0-r0",image_digest="esitcparis/unbound-autoupdate@sha256:…"} 1
unbound_autoupdate_last_cycle_timestamp_seconds 1789000012
unbound_autoupdate_last_cycle_duration_seconds 47
unbound_autoupdate_last_cycle_status{status="updated"} 1
unbound_autoupdate_cycles_total{status="up_to_date"} 214
unbound_autoupdate_quarantine_active{axis="image"} 0
unbound_autoupdate_target_image_info{digest="esitcparis/unbound-distroless@sha256:…",version="1.26.0"} 1
unbound_autoupdate_self_update_last_timestamp_seconds 0

unbound_exporter_scrape_success 1
unbound_exporter_scrape_duration_seconds 0.061
```

Two families are derived rather than copied from `unbound-control`:

- `unbound_response_time_percentile_seconds{percentile="50"|"95"|"99"}` —
  p50/p95/p99 of the recursion-time histogram (linear interpolation inside
  the bucket, as `histogram_quantile` would), for consumers that cannot
  compute quantiles from buckets. Cumulative since the counters were last
  reset, like the histogram.
- `unbound_trust_anchor_*` — the RFC 5011 state read from the resolver's
  `root.key`: `last_success_timestamp_seconds` and `next_probe_timestamp_seconds`
  of the root DNSKEY probe, `failed_probes` (consecutive failures) and one
  `key_info{keytag,state}` sample per known root KSK. Alert when the last
  success ages beyond a few days: that is the mechanism that carries the
  resolver across a root KSK rollover.


Anything `unbound-control` reports that has no family of its own lands in
`unbound_stat{name="…"}`, so a new statistic in a future Unbound release is
exported rather than dropped.

A scrape job and a set of alert rules — resolver down, SERVFAIL ratio, DNSSEC
validation stopped, stale or failed cycles, rollbacks, quarantines — are in
[`../docs/observability/`](../docs/observability/). The rules are checked by
`promtool check rules` in CI.

## Self-update

The sidecar keeps itself current, by default (`SELF_UPDATE=0` turns it off).
It runs at the end of a cycle that ended `up_to_date` or `updated`, and only
when no other helper is still at work.

The new sidecar image goes through the same guards as a resolver image: the
major-version refusal, the `RETRY_AFTER` quarantine (on its own `self` axis,
so a broken sidecar release never blocks resolver updates) and **cosign
verification, fail-closed**. An unsigned sidecar image is not run; it is
reported as a supply-chain incident and the cycle ends `blocked`.

The recreation itself cannot run inside the container being replaced — a
`docker compose up -d` issued from it dies the moment Compose stops it, before
the new container is started. So it runs in an **ephemeral helper container,
started from the new, already verified image**. The helper:

1. recreates the sidecar's own service **first and alone**, and requires it to
   be running, with no restart, 30 seconds later;
2. only then moves the other services of the project declared on that same
   image (the metrics endpoint) — so an image that cannot start costs one
   container instead of all of them, and `/metrics` keeps answering while the
   rollback happens;
3. on any failure, pins every service it moved back to the previous digest,
   quarantines the new one and notifies `critical`.

The helper writes the shared state file under the same lock a cycle uses,
waiting up to `SELF_LOCK_WAIT` (900 s) for it — and if that runs out it logs
an error and writes anyway, because losing the quarantine would relaunch a
sidecar image that cannot start, on every cycle, silently.

A sidecar running a **locally built** image (no repository digest) never
self-updates: there is nothing to compare against and nothing to roll back to.

## Verifying with your own key

Keyless verification against this repository's release workflow is the
default. For a private mirror that re-signs what it serves, mount the public
key read-only and point `COSIGN_PUBLIC_KEY` at it:

```yaml
    environment:
      COSIGN_PUBLIC_KEY: /keys/mirror.pub
      COSIGN_IGNORE_TLOG: "1"   # mirror signatures are not in the public Rekor log
    volumes:
      - /etc/unbound-keys/mirror.pub:/keys/mirror.pub:ro
```

The two modes are exclusive: with `COSIGN_PUBLIC_KEY` set, the identity and
issuer settings are not used. A key path that cannot be read is a refusal to
verify, not a fallback — the cycle stops.

**Which cosign is inside.** The image embeds the **cosign v3.1.3** CLI, copied
from `ghcr.io/sigstore/cosign/cosign` and pinned by digest in
`.build-state.json`. The release workflows still **sign** with cosign v2.6.5,
so the verify command documented in [docs/trust.md](../docs/trust.md) keeps
working for users on a v2 CLI; cosign v3 verifies v2-produced signatures, so
the sidecar's own fail-closed check is unaffected by the difference.

## What it does not do

- **Kubernetes.** This is Compose-native by design: it reads Compose labels,
  runs `docker compose` and pins rollbacks with a Compose override. On
  Kubernetes, a rollout plus a readiness probe already covers the same ground.
- **Containers outside Compose**, or in a different Compose project from the
  sidecar's own. Discovery starts from the sidecar's
  `com.docker.compose.project` label.
- **`network_mode: host`.** A host-networked container cannot be connected to
  another Docker network, so a host-networked sidecar cannot reach the
  canary's isolated network. The cycle says so and refuses up front, before
  creating a network, a volume, a state clone or a container. (A resolver in
  host mode also requires the sidecar to be in host mode, to probe it at all.)
- **Reverting your configuration.** The rollback override pins the previous
  *image*; it cannot un-edit a bind-mounted file. When the configuration is
  what changed, the notification says so explicitly and a human has to fix the
  file.
- **Grafana dashboards.** The exposition is plain Prometheus text; build or
  import whatever dashboard you like on top of it.
