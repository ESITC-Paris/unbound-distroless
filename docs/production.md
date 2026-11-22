# Production deployment

A reference deployment for running `esitcparis/unbound-distroless` as the
resolver an organisation depends on: two hosts, each with the resolver and the
[update sidecar](../updater/README.md), Prometheus alerts, and a runbook per
failure. What the sidecar does, its variables, notifications and metrics are
described in [updater/README.md](../updater/README.md); the alert and scrape
files are in [observability/](observability/).

Every command below was run on Docker Engine 29.9.3 with Compose v5.7.1
(arm64), against the files of this repository, unless it is marked *not run*.
The project files are checked in CI by `tests/sidecar-docs.sh` (Compose) and
`tests/observability.sh` (Prometheus).

## Reference architecture

```
             clients: resolv.conf / DHCP option 6 list BOTH addresses
                 │                                         │
   ┌─────────────▼──────────────┐            ┌─────────────▼──────────────┐
   │ host A  10.0.0.11          │            │ host B  10.0.0.12          │
   │ /opt/unbound               │            │ /opt/unbound               │
   │  unbound             :53   │            │  unbound             :53   │
   │  unbound-autoupdate  loop  │            │  unbound-autoupdate  loop  │
   │  unbound-metrics     :9167 │            │  unbound-metrics     :9167 │
   │ started at T               │            │ started at T + 30 min      │
   └─────────────┬──────────────┘            └─────────────┬──────────────┘
                 └───────────► Prometheus ◄────────────────┘
                     Healthchecks.io: one check per host (HC_URL)
```

Nothing is shared between the hosts. An update recreates the resolver
container, and the host answers nothing for the seconds that takes; the
second host, listed by every client, covers that window, and covers a host
whose resolver is down until someone intervenes (runbook (b)).

The sidecar runs a cycle when its container starts, then waits `INTERVAL`
plus a random delay of up to `SPLAY` before each next one
(`updater/entrypoint.sh`). With `INTERVAL=1h` and `SPLAY=10%` the cycles of
several hosts are spread over 6 minutes at most, and their phase drifts by up
to that much at each cycle. What keeps two hosts apart is starting them about
30 minutes apart.

## Host prerequisites

**Docker Engine with the Compose plugin, version 5 or later** (`docker
compose`, not the old `docker-compose`; 5.5.0 or later on the containerd
image store): the sidecar runs its own `docker compose`, and an older Compose
on the host recreates the resolver at its next `up -d` after each update
([why](../updater/README.md#what-a-cycle-does)). Older versions than the
ones above were not tested.

**Port 53.** The reference project publishes `53:53/udp` and `53:53/tcp` on
every host address. See what already listens:

```bash
ss -lntup 'sport = :53'
```

If something does (on Ubuntu, usually the `systemd-resolved` stub on
`127.0.0.53`), the fix is in the README, [Run it](../README.md#run-it).
Publishing on the host's LAN address only, for example
`"10.0.0.11:53:53/udp"`, also keeps the source address of clients visible to
`access-control` ([usage.md](usage.md#docker-run)).

**Socket buffers.** `unbound.conf` asks for 4 MiB receive and send buffers
(`so-rcvbuf`, `so-sndbuf`). The kernel limits `net.core.rmem_max` and
`net.core.wmem_max` are not namespaced: only the host can raise them.

```bash
sysctl net.core.rmem_max net.core.wmem_max    # 4194304 or more
```

To raise them (*not run*: it changes the host):

```bash
printf 'net.core.rmem_max = 4194304\nnet.core.wmem_max = 4194304\n' \
  | sudo tee /etc/sysctl.d/90-unbound.conf
sudo sysctl --system
```

When the limit is lower, Unbound starts anyway and logs
`warning: so-rcvbuf 4194304 was not granted.` with the size it got:

```bash
docker compose logs unbound | grep 'not granted'
```

**Open files.** `outgoing-range: 4096` times `num-threads: 2` needs 8192
descriptors for the outgoing port pool alone; the reference project sets
`nofile` to 16384. Raise both together.

**Clock.** DNSSEC signatures have a validity window: a host clock outside it
turns valid answers into SERVFAIL. Keep the host synchronised (NTP) and
monitored.

**Egress.**

| Destination | Used by |
|---|---|
| The registry: for Docker Hub `index.docker.io`, `auth.docker.io`, `production.cloudfront.docker.com` | Every cycle's pull, the canary, the self-update |
| `tuf-repo-cdn.sigstore.dev:443` | Keyless signature verification: with that name unreachable, `cosign verify` fails |
| The `auth-zone` primaries in `unbound.conf` (root servers), TCP and UDP 53 | The local root zone copy, refreshed by zone transfer. Without them, `fallback-enabled: yes` keeps resolution working on the copy in the image, which ages. |
| The Internet, TCP and UDP 53 | Recursion (no forwarders in `unbound.conf`) |
| Your `HC_URL` and `WEBHOOK_URL` hosts | Notifications |

## Project layout

```
/opt/unbound/
├── docker-compose.yml   # docs/production/docker-compose.yml
├── unbound.conf         # your configuration
├── .env                 # HC_URL, WEBHOOK_URL; mode 600
└── tls/                 # optional: certificate and key for DoT/DoH
```

The sidecar mounts this directory read-only at the **same absolute path**
(`/opt/unbound:/opt/unbound:ro`): see
[the same-absolute-path rule](../updater/README.md#the-same-absolute-path-rule).
Elsewhere than `/opt/unbound`, change the path on both sides of that mount.

## The reference project

[`production/docker-compose.yml`](production/docker-compose.yml), copied to
`/opt/unbound/docker-compose.yml`. Compared with the README's root
`docker-compose.yml` it adds the sidecar's two services, mounts
`unbound.conf`, and sets a memory limit and log rotation. On the test host,
`docker inspect` of the resolver showed `ReadonlyRootfs=true`,
`CapDrop=[ALL]`, `CapAdd=[CAP_NET_BIND_SERVICE]`,
`SecurityOpt=[no-new-privileges:true]`, `Ulimits=[nofile=16384:16384]`,
`Memory=536870912` and json-file logging with `max-size:10m`, `max-file:5`
(50 MiB per service at most).

The memory limit is twice the cache sizes of the shipped `unbound.conf`
(240 MiB in total): change it with them, or the resolver is killed when its
caches fill.

### What the resolver follows

The sidecar pulls the tag the compose file declares, at each cycle, and
deploys what it finds there after a canary.

| `image:` of the `unbound` service | Resolver updates |
|---|---|
| `esitcparis/unbound-distroless:1` (the file as shipped) | Automatic: each new release of major version 1. |
| An `X.Y.Z-rN` tag or `@sha256:` digest taken from the [releases page](https://github.com/ESITC-Paris/unbound-distroless/releases) | Only when you edit that line; the next cycle canaries and deploys the new value. An `X.Y.Z-rN` tag is published once and never moved, so a pinned file sees no new image. |

In both cases the sidecar still canaries and deploys configuration changes,
exports metrics and updates itself. The sidecar's own services follow
`esitcparis/unbound-autoupdate:1` in both cases: self-update needs a tag that
moves ([Self-update](../updater/README.md#self-update)). Choose the same mode
on every host.

## Secrets

`HC_URL` and `WEBHOOK_URL` are capability URLs: whoever holds them can mark a
check green or post to the alert channel. Keep them in `.env`, which Compose
reads from the project directory:

```bash
cd /opt/unbound
cat > .env <<'EOF'
HC_URL=https://hc-ping.com/<uuid>
EOF
chmod 600 .env
```

The compose file reads `${HC_URL:?set HC_URL in .env}`: without a value,
every `docker compose` command fails with that message instead of starting a
sidecar that alerts nobody. The values are visible in `docker inspect` of the
container and in `docker compose config`.

## Bring-up

On host A (commands from `/opt/unbound`):

```bash
curl -fsSLO https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/unbound.conf
# edit unbound.conf; copy docs/production/docker-compose.yml here; write .env

# The configuration, checked by the image and mounts the project declares
docker compose run --rm --no-deps --entrypoint /usr/local/sbin/unbound-checkconf \
  unbound /etc/unbound/unbound.conf
#   unbound-checkconf: no errors in /etc/unbound/unbound.conf

docker compose up -d
```

Then check, in this order:

```bash
docker compose ps                                     # unbound: (healthy)
dig @10.0.0.11 . SOA +dnssec | grep '^;; flags'       # flags include ad
dig @10.0.0.11 example.com +short
docker exec unbound /usr/local/sbin/unbound-control \
  -c /etc/unbound/unbound.conf list_auth_zones        # .  serial …
docker compose logs unbound-autoupdate                # baseline recorded, up to date
docker compose run --rm unbound-autoupdate check; echo $?   # 0
curl -s http://127.0.0.1:9167/metrics | grep '^unbound_exporter_scrape_success'   # 1
```

`check` runs a canary on a copy of production's state without swapping
([Validate without deploying](../updater/README.md#validate-without-deploying));
its exit code is described there. Bring host B up the same way about 30
minutes later, with its own `NOTIFY_HOST` and `HC_URL`.

## Alerts

Load [`observability/prometheus.yml`](observability/prometheus.yml) and
[`observability/alerts.yml`](observability/alerts.yml). The reference project
publishes `/metrics` on `127.0.0.1:9167`; for a Prometheus on another host,
publish it on the host's monitoring address instead (never on a public one:
the endpoint uses the Docker socket). The metrics themselves:
[updater/README.md](../updater/README.md#metrics).

| Alert | First action |
|---|---|
| `UnboundDown` | From a client, `dig @<host> . SOA`. No answer: runbook (b). An answer: the metrics service or the Docker socket is the problem, not DNS. |
| `UnboundServfailRatioHigh` | `docker compose logs unbound \| grep -i servfail` (the shipped configuration logs the reason), then upstream reachability and the host clock. |
| `UnboundNoDnssecValidation` | `dig @<host> . SOA +dnssec`: no `ad` flag means no validation. Check that the `unbound-data` volume is mounted and was not recreated empty. |
| `UnboundTrustAnchorProbeStale` | Check that the root servers are reachable from the resolver and that `/var/lib/unbound` is writable. |
| `UnboundAutoupdateStale` | `docker compose ps unbound-autoupdate` and its logs. |
| `UnboundAutoupdateFailed` | The sidecar's log and notification name the reason ([Behaviour](../updater/README.md#behaviour)). A signature refused or not checkable: runbook (d). |
| `UnboundAutoupdateRolledBack` | Runbook (a). |
| `UnboundAutoupdateCritical` | Runbook (b). |
| `UnboundAutoupdateQuarantined` | Runbook (a), (c) or (e), by the `axis` label. |

Healthchecks.io: one check per host, with a grace time longer than
`INTERVAL` plus `SPLAY`.

## Runbooks

The commands assume the reference project: one `docker-compose.yml` in
`/opt/unbound`, run from that directory. With the sidecar installed as
`docker-compose.override.yml`, add `-f docker-compose.override.yml` after
every `-f docker-compose.yml`. The sidecar's state:

```bash
docker compose exec -T unbound-autoupdate cat /var/lib/unbound-autoupdate/state.env
```

The keys are described in [updater/README.md](../updater/README.md#state).

### (a) An update was rolled back

Notification `ROLLBACK performed`, alert `UnboundAutoupdateRolledBack`. The
new image or configuration failed its checks after the swap; the previous
image serves again, and what changed (image, configuration or both) is
quarantined for `RETRY_AFTER`.

1. Check that production answers: `dig @<host> . SOA +dnssec` shows `ad`.
2. Read why: `docker compose logs --since 2h unbound-autoupdate`.
3. If the notification says the configuration was not reverted, fix or
   revert the files yourself: a rollback restores the image only.
4. Do not run `docker compose pull`. The local tag was put back on the
   previous image, so `docker compose up -d` alone keeps it; a pull followed
   by `up -d` would deploy the failing image without any check. (If the
   compose file declares a digest, `up -d` deploys that digest: change the
   line first.)
5. Test a fix without touching production:
   `docker compose run --rm unbound-autoupdate check`. While the failed value
   is still the declared one, `check` ends `skipped` (exit 2) on the
   quarantine: change what is declared, or lift the quarantine (runbook (e)).
6. Otherwise the sidecar tries the same value again once `RETRY_AFTER` has
   elapsed, and rolls back again if it still fails.

### (b) The resolver is down on this host

Notification `CRITICAL: rollback failed`, alert `UnboundAutoupdateCritical`,
or `UnboundDown` with no DNS answer. After a failed rollback the next cycle
tries once more; if that fails too, the sidecar leaves the resolver as it
finds it.

1. Check from a client that the other host answers.
2. If the notification says the configuration was not reverted, revert it
   first: the previous image will not start on a broken configuration
   either.
3. Stop the sidecar: `docker compose stop unbound-autoupdate`.
4. Find a known-good digest: `LAST_IMAGE_DIGEST` in `state.env` is the image
   of the last successful update (or of the baseline); the releases page
   lists every published digest.
5. Pin the resolver to it with an override file **in the project
   directory**, where the sidecar can read it:

   ```bash
   cat > pin.yml <<'EOF'
   services:
     unbound:
       image: esitcparis/unbound-distroless@sha256:<known-good>
   EOF
   docker compose -f docker-compose.yml -f pin.yml up -d --no-deps unbound
   dig @127.0.0.1 . SOA +dnssec | grep '^;; flags'
   ```

6. Once DNS answers, start the sidecar again:
   `docker compose start unbound-autoupdate`. If a swap is still recorded,
   its first cycle settles it first
   ([What a cycle does](../updater/README.md#what-a-cycle-does), step 3).

   Compose records the file list on the container, and the sidecar reads the
   project from that list: while the pin is in place, the pinned digest is the
   declared image, and the cycles end `up to date`.
7. To hand control back: `rm pin.yml && docker compose up -d --no-deps unbound`.

### (c) The sidecar's self-update failed

Notification `sidecar self-update FAILED — rolled back`, or
`CRITICAL: sidecar self-update FAILED and rollback failed`; alert
`UnboundAutoupdateQuarantined` with `axis="self"`. The resolver is not
involved; the sidecar, and possibly `/metrics`, are.

1. A helper container may still be at work:
   `docker ps --filter label=unbound-autoupdate.helper=1`. It is removed when
   it exits: read `docker logs <id>` while it runs.
2. `docker compose ps`: which image do `unbound-autoupdate` and
   `unbound-metrics` run? Do not run `docker compose pull` on them: the
   failing image would come back without verification.
3. To hold the sidecar on a known-good image while the failure is
   investigated, pin both of its services by digest, in the project
   directory:

   ```bash
   cat > pin.yml <<'EOF'
   services:
     unbound-autoupdate:
       image: esitcparis/unbound-autoupdate@sha256:<known-good>
     unbound-metrics:
       image: esitcparis/unbound-autoupdate@sha256:<known-good>
   EOF
   docker compose -f docker-compose.yml -f pin.yml up -d --no-deps unbound-autoupdate unbound-metrics
   ```

   Self-update reads the files its own container was created from, so it
   sees the pin and leaves those services alone. To undo:
   `rm pin.yml && docker compose up -d --no-deps unbound-autoupdate unbound-metrics`.
   `SELF_UPDATE=0` disables self-update altogether.

### (d) Signature verification failed, or could not be done

The cycle ends `blocked` with one of four notifications. In every case
nothing was deployed or recreated, and a new image that was refused or could
not be checked was never run.

**`signature could not be checked`** or **`sidecar signature could not be
checked`**: the registry (often its rate limit) or the transparency log did
not answer. Not a security event. Check the host's access to the registry
and to `tuf-repo-cdn.sigstore.dev`, and the registry credentials
(`DOCKER_CONFIG`). The next cycle tries again.

**`signature verification FAILED`** or **`sidecar signature verification
FAILED`**: a signature was checked and refused. Treat it as a security
event. If the refused image is the one already running, it keeps serving (the
notification says so), but nothing is canaried or recreated on it.

1. Do not work around it: do not change `COSIGN_PUBLIC_KEY`,
   `COSIGN_IGNORE_TLOG` or the identity and issuer variables to make it pass.
2. Verify the digest from the log by hand, with the commands in
   [trust.md](trust.md#verifying-releases), and compare it with the digests
   on the releases page.
3. A digest this project did not publish: a registry or account compromise.
   Stop updates on every host (`docker compose stop unbound-autoupdate`) and
   report it ([SECURITY.md](../SECURITY.md)).
4. A published digest that does not verify: report it as well; the fix is in
   the release pipeline.

### (e) Lifting a quarantine early

A quarantined value is retried once `RETRY_AFTER` has elapsed, or at once if
the declared value changes. To retry the same value earlier, either lower
`RETRY_AFTER` in the sidecar's environment and run `docker compose up -d`
(the window is evaluated at each cycle, for every axis), or clear the keys
with the sidecar stopped:

```bash
docker compose stop unbound-autoupdate
docker compose run --rm --no-deps --entrypoint /bin/sh unbound-autoupdate -c \
  "sed -i -e 's/^QUARANTINE_DIGEST=.*/QUARANTINE_DIGEST=/' \
          -e 's/^QUARANTINE_TS=.*/QUARANTINE_TS=/' \
          /var/lib/unbound-autoupdate/state.env"
docker compose start unbound-autoupdate
```

Use `CONFIG_QUARANTINE_HASH` and `CONFIG_QUARANTINE_TS` for the configuration
axis, `SELF_QUARANTINE_DIGEST` and `SELF_QUARANTINE_TS` for the sidecar. The
value goes through the full canary again.

### (f) Backing up and restoring the volumes

`unbound_unbound-data` holds the trust anchor (`root.key`) and the root zone
copy; `unbound_autoupdate-state` holds the sidecar's state. Any image with a
shell and `tar` will do; the sidecar's image is already on the host. While
the resolver is stopped, expect `UnboundDown` and `UnboundAutoupdateFailed`.

```bash
docker compose stop unbound unbound-autoupdate
docker run --rm --entrypoint /bin/sh \
  -v unbound_unbound-data:/src:ro -v "$PWD/backup":/backup \
  esitcparis/unbound-autoupdate:1 \
  -c 'tar czf /backup/unbound-data.tgz --numeric-owner -C /src .'
docker run --rm --entrypoint /bin/sh \
  -v unbound_autoupdate-state:/src:ro -v "$PWD/backup":/backup \
  esitcparis/unbound-autoupdate:1 \
  -c 'tar czf /backup/autoupdate-state.tgz --numeric-owner -C /src .'
docker compose start unbound unbound-autoupdate
```

Restore into new, empty volumes (`docker compose down` keeps volumes; `-v`
removes them, and `up --no-start` creates them again):

```bash
docker compose down -v
docker compose up --no-start
for v in unbound-data autoupdate-state; do
  docker run --rm --entrypoint /bin/sh \
    -v "unbound_$v":/dst -v "$PWD/backup":/backup:ro \
    esitcparis/unbound-autoupdate:1 \
    -c "tar xzf /backup/$v.tgz --numeric-owner -C /dst"
done
docker compose up -d
```

`--numeric-owner` keeps the files owned by UID and GID 65532, the resolver's
user. Without a backup, a lost `unbound-data` starts the resolver from the
anchor and zone in the image; a lost `autoupdate-state` makes the next cycle
record a new baseline.

### (g) Upgrading the sidecar by hand

When `SELF_UPDATE=0`, or after a self-update failure you have resolved:

```bash
docker compose pull unbound-autoupdate unbound-metrics
docker compose up -d --no-deps unbound-autoupdate unbound-metrics
```

`docker compose pull` does not verify signatures: verify the pulled digest
first ([trust.md](trust.md#verifying-releases)). The resolver is not
recreated; the state volume, and with it the baseline, counters and
quarantines, is kept.

### (h) Rotating a certificate under `tls/`

The sidecar fingerprints every file of every declared bind mount, so a new
certificate is canaried and deployed like a configuration change. A directory
mount that contains no file, or a symbolic link to a missing file, stops the
cycle: replace the directory in one step.

```bash
install -d -m 755 tls.new
cp fullchain.pem tls.new/server.pem
cp privkey.pem tls.new/server.key
mv tls tls.old && mv tls.new tls
docker compose run --rm unbound-autoupdate check   # exit 0
```

The next cycle deploys it. A rollback, if the new certificate fails after
the swap, does not restore `tls.old`: runbook (a), step 3.

## Go-live checklist

- [ ] Two hosts; on each, the project directory at the path mounted on both
      sides of the sidecar's bind mount.
- [ ] Port 53 free on the published address; socket buffer limits of at
      least 4194304; clock synchronised; egress open.
- [ ] `unbound.conf` accepted by `unbound-checkconf` of the declared image.
- [ ] `.env` with one `HC_URL` per host, mode 600; `NOTIFY_HOST` per host.
- [ ] The same resolver tag mode on both hosts.
- [ ] Both resolvers `healthy`, `ad` in `dig … . SOA +dnssec`.
- [ ] `docker compose run --rm unbound-autoupdate check` exits 0 on both.
- [ ] Prometheus scrapes both hosts; `alerts.yml` loaded and routed to a
      person; Healthchecks.io receives both hosts.
- [ ] Host B started about 30 minutes after host A.
- [ ] Clients list both addresses; `docker compose stop unbound` on one host
      leaves them resolving.
- [ ] Backups taken and a restore rehearsed (runbook (f)).
- [ ] On-call staff know that the sidecar's Docker socket is root on the
      host ([updater/README.md](../updater/README.md#the-docker-socket-is-root-on-the-host)).

What the sidecar does not do:
[updater/README.md](../updater/README.md#what-it-does-not-do).
