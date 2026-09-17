# Production deployment guide

## Audience and outcome

This guide is for the operator who has to run `esitcparis/unbound-distroless`
as the DNS resolver a company actually depends on, and who will be paged when
it breaks. It describes a two-host reference deployment, the host preparation
it needs, a hardened Compose project that was brought up and validated on a
real Docker daemon before being written down here, what to put in Prometheus,
and the runbook for every failure the update sidecar can report. Everything
below is derived from the files in this repository and from commands that were
run; where something could not be verified on the machine this guide was
written on, it says so instead of guessing.

## Reference architecture

Two independent hosts. Each runs one resolver, one `unbound-autoupdate` in
`loop` mode, and one `unbound-metrics`. Nothing is shared between the hosts:
no cluster, no shared state, no leader. Clients are configured with **both**
resolver addresses.

```
                 clients — resolv.conf / DHCP option 6 lists BOTH
                    │                                      │
        ┌───────────┘                                      └───────────┐
        ▼                                                              ▼
┌──────────────────────────────────┐        ┌──────────────────────────────────┐
│ host A — 10.0.0.11               │        │ host B — 10.0.0.12               │
│  /opt/unbound (compose project)  │        │  /opt/unbound (compose project)  │
│                                  │        │                                  │
│  ┌────────────────────────────┐  │        │  ┌────────────────────────────┐  │
│  │ unbound            :53     │  │        │  │ unbound            :53     │  │
│  │ read_only, cap NET_BIND    │  │        │  │ read_only, cap NET_BIND    │  │
│  └──────────────▲─────────────┘  │        │  └──────────────▲─────────────┘  │
│                 │ canary + swap  │        │                 │ canary + swap  │
│  ┌──────────────┴─────────────┐  │        │  ┌──────────────┴─────────────┐  │
│  │ unbound-autoupdate  (loop) │  │        │  │ unbound-autoupdate  (loop) │  │
│  │ INTERVAL=1h  SPLAY=10%     │  │        │  │ INTERVAL=1h  SPLAY=10%     │  │
│  └──────────────┬─────────────┘  │        │  └──────────────┬─────────────┘  │
│                 │ state volume   │        │                 │ state volume   │
│  ┌──────────────┴─────────────┐  │        │  ┌──────────────┴─────────────┐  │
│  │ unbound-metrics     :9167  │  │        │  │ unbound-metrics     :9167  │  │
│  └──────────────┬─────────────┘  │        │  └──────────────┬─────────────┘  │
│  started at T                    │        │  started at T + 30 min           │
└─────────────────┼────────────────┘        └─────────────────┼────────────────┘
                  │                                           │
                  └──────────► Prometheus ◄───────────────────┘
                     Healthchecks.io: one check per host (HC_URL)
```

Why two hosts. A successful update is a **recreation of the resolver
container** — `updater/unbound-autoupdate` logs `swapping <service> (brief
restart)` and then runs `docker compose up -d --no-deps` on that one service.
The container is stopped and a new one is started; during that window this
host answers nothing. A second resolver on a second host, listed in every
client's resolver list, is what makes that window invisible to clients. It is
also what covers the case the sidecar cannot fix by itself: the `critical`
outcome, where both the swap and the rollback failed.

Why staggering matters, and what actually staggers. `updater/entrypoint.sh`
runs a cycle **immediately** when the container starts, then sleeps
`INTERVAL` plus a random jitter of up to `SPLAY` (`SPLAY` is a percentage of
`INTERVAL`, or an absolute duration), and repeats. That jitter is drawn
per-cycle inside one container — it spreads a fleet's cycles over the hour,
but it does not put two hosts in a fixed opposite phase, and it makes any
phase you set drift by up to `SPLAY` each cycle. What separates two hosts is
**when you start them**: bring host B up about 30 minutes after host A and
their first cycles are 30 minutes apart. Observed on the test run with
`INTERVAL=1h SPLAY=10%`:

```
ts=2026-09-17T09:32:06Z level=info msg="next cycle in 3671s"
```

3600 s + 71 s of jitter, within the 0–360 s (10 % of 1 h) the code allows.

## Host prerequisites

### Docker Engine and Compose v2

The sidecar shells out to `docker compose` for everything it does:
`compose pull --quiet`, `compose config --format json`, `compose ps -q`,
`compose up -d --no-deps [--force-recreate]`. `--format json` on
`compose config` and `-p/--project-directory` handling as used in
`updater/lib/discover.sh` are Compose **v2** (the `docker compose`
subcommand, not the old `docker-compose` script).

Versions this guide was tested with:

```console
$ docker compose version
Docker Compose version v5.5.1
$ docker version --format '{{.Server.Version}}'
29.8.0
```

Older Engine/Compose combinations were not tested here, so no minimum is
claimed beyond "Compose v2".

### A free port 53

The reference file publishes `53:53/udp` and `53:53/tcp` on all host
addresses. Before the first `docker compose up -d`, find out what already
holds port 53:

```bash
ss -lntup 'sport = :53'          # what is listening, and which process
systemctl is-active systemd-resolved
```

On Ubuntu, `systemd-resolved` normally binds its stub listener on
**127.0.0.53:53**. Whether that conflicts with a container publishing
`0.0.0.0:53` could **not be verified for this guide** — the smoke test ran on
Docker Desktop on macOS, where there is no systemd — so this guide does not
tell you to set `DNSStubListener=no`. Check first, and decide from what `ss`
shows:

- nothing on the address you publish → nothing to do;
- `docker compose up -d` fails with an "address already in use" bind error →
  either free the address (on Ubuntu that means `DNSStubListener=no` in
  `/etc/systemd/resolved.conf` plus `systemctl restart systemd-resolved`, and
  repointing `/etc/resolv.conf`), or publish on a specific LAN address
  instead: `"10.0.0.11:53:53/udp"`.

Related, and worth knowing before you pick: `docs/usage.md` notes that with
`-p 53:53` on all interfaces, client source addresses can be rewritten to the
bridge gateway by Docker's userland proxy, which the shipped ACL allows.
Publishing on a specific LAN address keeps `access-control` meaningful.

### Kernel socket buffers

`unbound.conf` asks for 4 MiB socket buffers:

```
  so-rcvbuf: 4m
  so-sndbuf: 4m
```

These are clamped by `net.core.rmem_max` / `net.core.wmem_max`, which are
**not namespaced** — the container cannot raise them, only the host can. 4m
is 4194304 bytes:

```bash
sysctl net.core.rmem_max net.core.wmem_max          # current values
printf 'net.core.rmem_max = 4194304\nnet.core.wmem_max = 4194304\n' \
  | sudo tee /etc/sysctl.d/90-unbound.conf
sudo sysctl --system
```

If the kernel value is lower, Unbound logs that the buffer "was not granted"
and runs with the smaller one — harmless, but it is the signal that the
sysctl is missing. On the host used for the smoke test both values were
already `4194304` and no such line appeared in the resolver log, so the
warning text itself is quoted here from `unbound.conf` and `docs/usage.md`,
not from an observed run. Grep for it after bring-up:

```bash
docker compose logs unbound | grep -i 'not granted'
```

### Open files

`unbound.conf` declares `outgoing-range: 4096` and `num-threads: 2`, so the
outgoing port pool alone wants 4096 × 2 = **8192** descriptors, before the
listening sockets, `incoming-num-tcp: 128`, `outgoing-num-tcp: 32` and the
control socket. The reference file sets `nofile` to 16384 soft and hard —
8192 rounded up with headroom. `docs/usage.md` suggests `nofile=65535:65535`
for high-traffic deployments; raise `outgoing-range`, `num-threads` and this
limit together, and verify:

```bash
docker inspect unbound --format '{{.HostConfig.Ulimits}}'
docker compose logs unbound | grep -i 'reduc'   # unbound says so when it lowers the pool
```

Verified on the test run: `Ulimits=[nofile=16384:16384]`, and no reduction
line in the resolver log.

### Time synchronisation

DNSSEC signatures carry an inception and an expiration. From the smoke test:

```
.  86386  IN  RRSIG  SOA 8 0 86400 20260929050000 20260916040000 57780 . ...
```

A host clock outside that window makes valid signatures look expired or
not-yet-valid, and a validating resolver answers SERVFAIL. Keep the host
synchronised and alert on it:

```bash
timedatectl status          # "System clock synchronized: yes"
chronyc tracking            # or the equivalent for your NTP daemon
```

### Egress

| Destination | Why | How to test |
|---|---|---|
| Your container registry (Docker Hub for the image references in this guide) | `docker compose pull` every cycle; the canary and the preflight run the pulled image | `docker pull esitcparis/unbound-distroless:1.26.1-r0` |
| Sigstore public-good infrastructure (cosign keyless trust material) | `updater/lib/verify.sh` runs `cosign verify` fail-closed before any new image is deployed | the command below |
| Root servers, TCP/53 and UDP/53, to the `auth-zone` primaries in `unbound.conf` | RFC 8806 hyperlocal root: Unbound keeps `/var/lib/unbound/root.zone` fresh by AXFR/IXFR from those 14 addresses | `unbound-control list_auth_zones` |
| The public internet, UDP/53 and TCP/53 | full recursion: `module-config: "validator iterator"`, no forwarders | `dig @<resolver> example.com` |

Signature verification, run from the sidecar image exactly as the sidecar
runs it — this is both the egress test and the manual check for runbook (d).
Any image carrying the `cosign` binary, or a local `cosign`, does the same job:

```console
$ docker run --rm --entrypoint cosign esitcparis/unbound-autoupdate:1 verify \
    --certificate-identity-regexp 'https://github.com/ESITC-Paris/unbound-distroless/.*' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    esitcparis/unbound-distroless:1.26.1-r0

Verification for index.docker.io/esitcparis/unbound-distroless:1.26.1-r0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

Root zone transfer, confirmed on the test resolver a few seconds after start:

```console
$ docker exec unbound /usr/local/sbin/unbound-control \
    -c /etc/unbound/unbound.conf list_auth_zones
.	serial 2026091600	 since 1789637523 2026-09-17T09:32:03
```

If your egress policy blocks AXFR to the root servers, the zone simply stays
at the copy baked into the image and `fallback-enabled: yes` keeps resolution
working through ordinary recursion — but you lose the hyperlocal benefit and
the copy ages.

## Directory layout on the host

```
/opt/unbound/
├── docker-compose.yml      # the reference project below
├── unbound.conf            # your configuration (start from the repo's)
├── .env                    # HC_URL, WEBHOOK_URL — mode 600, never committed
└── tls/                    # optional: certificate + key for DoT/DoH
```

**The path must be the same inside the sidecar as on the host.** The sidecar
runs `docker compose` itself against these files, using the file list Compose
stamped on the resolver container; Compose resolves the project's relative
bind mounts against the project directory and the Docker daemon applies them
on the host. A path that means one thing in the sidecar and another on the
host would deploy the wrong files. `updater/lib/discover.sh` refuses to guess:

```
compose file '/opt/unbound/docker-compose.yml' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path
```

and, for each declared bind-mount source:

```
declared bind mount '<src>' is not readable from inside the sidecar — it must be mounted read-only at the same absolute path
```

So `- /opt/unbound:/opt/unbound:ro` in the sidecar service, and if you put the
project anywhere else, that path changes on **both** sides.

## The reference Compose project

The file is [`production/docker-compose.yml`](production/docker-compose.yml)
in this repository; copy it to `/opt/unbound/docker-compose.yml`.

```yaml
name: unbound

services:
  unbound:
    # MODE A — pinned, manual updates (this file's default).
    # MODE B — tracking a major tag: esitcparis/unbound-distroless:1
    image: esitcparis/unbound-distroless:1.26.1-r0
    container_name: unbound
    restart: unless-stopped
    stop_grace_period: 20s

    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]

    read_only: true
    tmpfs:
      - "/run/unbound:uid=65532,gid=65532"

    ports:
      - "53:53/udp"
      - "53:53/tcp"

    volumes:
      - unbound-data:/var/lib/unbound
      - ./unbound.conf:/etc/unbound/unbound.conf:ro
      # - ./tls:/etc/unbound/tls:ro

    ulimits:
      nofile:
        soft: 16384
        hard: 16384

    deploy:
      resources:
        limits:
          memory: 512m

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

  unbound-autoupdate:
    image: esitcparis/unbound-autoupdate:1
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      INTERVAL: 1h
      SPLAY: 10%
      NOTIFY_HOST: resolver-1.example
      HC_URL: ${HC_URL:?set HC_URL in .env}
      # WEBHOOK_URL: ${WEBHOOK_URL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/unbound:/opt/unbound:ro
      - autoupdate-state:/var/lib/unbound-autoupdate
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "5" }

  unbound-metrics:
    image: esitcparis/unbound-autoupdate:1
    command: ["metrics"]
    restart: unless-stopped
    ports:
      - "127.0.0.1:9167:9167"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - autoupdate-state:/var/lib/unbound-autoupdate:ro
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "5" }

volumes:
  unbound-data:
  autoupdate-state:
```

The two sidecar services are `updater/compose.snippet.yml` verbatim, plus
`SPLAY`, `NOTIFY_HOST`, `stop_grace_period` and log rotation.

### Which tag the resolver should follow

The sidecar updates the resolver by re-pulling the tag the compose file
**declares** and comparing repository digests
(`updater/unbound-autoupdate`: `compose pull --quiet "$TARGET_SERVICE"`, then
`declared_digest` against `running_digest`). That has one consequence worth
stating plainly:

| | Mode A — pinned | Mode B — tracking `:1` |
|---|---|---|
| `image:` | `esitcparis/unbound-distroless:1.26.1-r0` | `esitcparis/unbound-distroless:1` |
| Resolver updates | never automatically: an `X.Y.Z-rN` tag is immutable, so the pull always yields the same digest and every cycle ends `up_to_date` | automatically, whenever the tag moves |
| What the sidecar still does | pulls, fingerprints your configuration, canaries and redeploys on **configuration** changes, exports metrics, self-updates | all of that, plus resolver image updates |
| Upgrading | you edit the tag; the next cycle canaries and deploys it | the sidecar canaries and deploys it |
| Verified here | `1.26.1-r0` exists on Docker Hub (`docker buildx imagetools inspect`), the cycle recorded a baseline and then `up to date` | the `1`, `1.26`, `1.26.1` and `latest` tags exist on Docker Hub |

Mode A is the honest default for an environment where every production change
must be a deliberate, ticketed act — you still get the canary, because the
cycle canaries the new digest when *you* move the tag. Mode B is what buys you
the unattended CVE-response the sidecar exists for. Pick one per fleet, not
per host.

The **sidecar** follows `:1` in both modes, and that is not an inconsistency:
it replaces itself (`updater/lib/selfupdate.sh`), and
`_self_running_digest`/`declared` comparison needs the declared tag to move
for anything to happen. Pin the sidecar immutably and you freeze the updater,
not the resolver.

> At the time this guide was written, `esitcparis/unbound-autoupdate` had **no
> published tags** on Docker Hub (`docker buildx imagetools inspect
> esitcparis/unbound-autoupdate:1` → `not found`; the Hub tag list is empty).
> The smoke test below therefore ran against a locally built
> `unbound-autoupdate:test`. Confirm the tag resolves before your first
> bring-up.

### Why each hardening line is there

- `cap_drop: [ALL]` + `cap_add: [NET_BIND_SERVICE]` + `no-new-privileges` —
  the same set the README and `docs/usage.md` document; the binary carries
  `cap_net_bind_service` so it can bind :53 as UID 65532.
- `read_only: true` + `tmpfs: /run/unbound` — the image writes in exactly two
  places: `/var/lib/unbound` (trust anchor and root zone; the named volume)
  and `/run/unbound` (control socket and PID file, from `unbound.conf`). The
  tmpfs is owned by 65532 so the non-root process can create the socket the
  `HEALTHCHECK` connects to. **Verified:** with `read_only: true` the
  container reached `healthy`, answered with the AD flag, and the sidecar's
  canary — which replicates `read_only`, `tmpfs`, `environment`, `ulimits`
  and `sysctls` from the declaration (`_read_declared_runtime`) — validated
  under the same settings.
- `unbound-data:/var/lib/unbound` as a **named** volume — not optional: the
  sidecar refuses a resolver without one ("no named volume on
  /var/lib/unbound — required to persist the DNSSEC trust anchor and to clone
  state for the canary").
- `deploy.resources.limits.memory: 512m` — arithmetic from `unbound.conf`:
  `msg-cache-size 64m + rrset-cache-size 128m + key-cache-size 32m +
  neg-cache-size 16m = 240m`, plus the infra cache (`infra-cache-numhosts:
  50000`), per-thread buffers and the binary. 512m is roughly 2× the cache
  total. **Resize it with the cache sizes, never on its own** — a resolver
  OOM-killed at its cache high-water mark is an outage that looks like a
  crash loop. Verified applied: `Memory=536870912`; the resolver sat at
  25.1 MiB / 512 MiB in a freshly started, lightly queried state, which is
  the floor, not the steady state. Compose v2 honours
  `deploy.resources.limits.memory` outside Swarm; `mem_limit: 512m` is the
  equivalent older spelling — use one, not both.
- `ulimits.nofile` — see *Open files* above.
- `logging` — `json-file` with `max-size: 10m` and `max-file: 5` caps each
  service at 50 MiB. Without it the default json-file driver never rotates.
  Verified applied: `LogConfig={json-file map[max-file:5 max-size:10m]}`.
- `stop_grace_period` — how long Docker waits between SIGTERM and SIGKILL
  when the service is stopped or recreated (default 10s). Verified applied:
  `StopTimeout=20`.
- `restart: unless-stopped` — on all three services, so a daemon restart
  brings back the resolver *and* its updater.

## Secrets

`HC_URL` and `WEBHOOK_URL` are capability URLs: anyone holding them can flip
your monitoring green or post to your alerting channel. They belong in a
`.env` file next to the compose file, which Compose reads automatically:

```bash
cd /opt/unbound
cat > .env <<'EOF'
HC_URL=https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
WEBHOOK_URL=https://hooks.example/services/...
EOF
chmod 600 .env
chown root:root .env
```

The compose file references them as `${HC_URL:?set HC_URL in .env}`, so a
missing value fails `docker compose config` instead of silently starting a
sidecar that alerts nobody. They are never baked into an image and never
appear in `docker inspect` of the *image*. They do appear in `docker inspect`
of the container and in `docker compose config` output — treat both as
sensitive, and keep `.env` out of git (the repository's `.gitignore` is not a
substitute for checking).

**Verified:** the smoke test ran with a mode-600 `.env` containing
`HC_URL=http://127.0.0.1:9/hc`; the sidecar picked it up and logged
`healthchecks ping failed` when that endpoint refused the connection.

## Bring-up

```bash
# 1. Lay the project down
sudo install -d -m 755 /opt/unbound
cd /opt/unbound
sudo curl -fsSLo unbound.conf \
  https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/unbound.conf
# edit unbound.conf, put docs/production/docker-compose.yml here, write .env

# 2. Validate the configuration with the image that will run it
docker run --rm -v /opt/unbound/unbound.conf:/etc/unbound/unbound.conf:ro \
  --entrypoint /usr/local/sbin/unbound-checkconf \
  esitcparis/unbound-distroless:1.26.1-r0 /etc/unbound/unbound.conf
# → unbound-checkconf: no errors in /etc/unbound/unbound.conf

# 3. Validate the project itself (catches a missing .env value)
docker compose config --quiet

# 4. Start
docker compose up -d
```

Verify, in this order:

```bash
# Resolver healthy (the image ships a HEALTHCHECK: unbound-control status)
docker compose ps
docker inspect unbound --format '{{.State.Health.Status}}'     # healthy

# DNSSEC validation live — the 'ad' flag must be in the flags line
dig @10.0.0.11 . SOA +dnssec | grep -E '^;; flags'
#   ;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

# Ordinary recursion
dig @10.0.0.11 example.com +short

# Hyperlocal root zone transferred
docker exec unbound /usr/local/sbin/unbound-control \
  -c /etc/unbound/unbound.conf list_auth_zones

# The sidecar took its baseline
docker compose logs unbound-autoupdate
#   ... msg="unbound-autoupdate <version> starting: interval=1h splay=10%"
#   ... msg="baseline recorded (image esitcparis/unbound-distroless@sha256:…)"
#   ... event=baseline subject="baseline recorded"
#   ... msg="up to date (esitcparis/unbound-distroless@sha256:…)"
#   ... msg="next cycle in 3671s"

# Full dress rehearsal: pull, cosign, preflight, canary on a clone of
# production state, DNS validation — and no swap. Exit 0 means the declared
# image and configuration are deployable.
docker compose run --rm unbound-autoupdate check
echo $?        # 0

# Metrics
curl -s http://127.0.0.1:9167/metrics | grep -c '^unbound_'      # > 0
```

`check` output from the smoke test:

```
ts=… level=info msg="preflight: configuration accepted by esitcparis/unbound-distroless@sha256:0d80…"
ts=… level=info msg="canary running at 192.168.224.2 on esitcparis/unbound-distroless@sha256:0d80…"
ts=… level=info msg="canary validated: image, production state and configuration work together"
ts=… level=info msg="check mode: everything validated, no swap performed"
```

Then bring host B up the same way, about 30 minutes later, with
`NOTIFY_HOST: resolver-2.example` and its own `HC_URL`.

## Observability

The scrape config and the alert rules live in
[`observability/`](observability/) and are checked by `promtool check rules`
in CI. The scrape config:

```yaml
scrape_configs:
  - job_name: unbound
    scrape_interval: 30s
    static_configs:
      - targets: ['resolver-1.example:9167', 'resolver-2.example:9167']

rule_files:
  - alerts.yml
```

One endpoint per host carries three sources: the resolver's own counters
(converted from `unbound-control stats_noreset`), the updater's state (read
from `metrics.prom` in the shared state volume) and the scrape itself, so a
resolver that cannot be reached shows up as `unbound_exporter_scrape_success
0` rather than as missing data. `/metrics` needs the Docker socket — publish
it on loopback or on a private monitoring interface, never publicly. If you
change `METRICS_PORT`, change the container side of the `ports:` mapping to
match (`updater/lib/metrics.sh` binds the port it is given).

### The alerts, what they mean, and the first action

| Alert | What happened | First action |
|---|---|---|
| `UnboundDown` (critical, 2m) | The scrape cannot reach `unbound-control` in the resolver container, or Prometheus cannot reach the endpoint at all. | Check clients first: `dig @<host> . SOA`. If DNS is dead, go to runbook (b). If DNS answers, the metrics sidecar or the socket is the problem, not the resolver. |
| `UnboundServfailRatioHigh` (warning, 10m) | More than 5 % of answers are SERVFAIL over 5 minutes. | `docker compose logs unbound \| grep -i servfail` — `log-servfail: yes` prints the reason. Then check upstream reachability and the host clock (DNSSEC signatures expire). |
| `UnboundNoDnssecValidation` (warning, 1h) | Queries are flowing but nothing validated in an hour. | Confirm with `dig @<host> . SOA +dnssec` (no `ad` = not validating). Check `/var/lib/unbound/root.key` is on the named volume and readable, and that the volume was not recreated empty. |
| `UnboundAutoupdateStale` (warning, 10m after 3h) | No cycle finished for over three hours; with `INTERVAL=1h` three should have. | `docker compose ps unbound-autoupdate` and its logs. A cycle that died mid-way records itself as `error` on the way out; a container that is gone records nothing at all. |
| `UnboundAutoupdateFailed` (warning, 5m) | The last cycle ended `blocked` or `error`: pull failure, fingerprint failure, cosign refusal, preflight rejection, or a canary that could not start or did not validate. **Production was not touched.** | Read the sidecar log for the specific line. If it is a cosign refusal, go to runbook (d) — that one is a security event, not an operations event. |
| `UnboundAutoupdateRolledBack` (warning) | A swap failed its post-swap gate in the last hour; production was restored and the change quarantined. | Runbook (a). |
| `UnboundAutoupdateCritical` (critical) | The swap failed **and** the rollback did not restore a working resolver. | Runbook (b), now. Clients should already be on the other host. |
| `UnboundAutoupdateQuarantined` (warning, 30m) | An image, a configuration or a sidecar image is being held back. The `axis` label says which. | Runbook (a), (c) or (e). Decide before `RETRY_AFTER` (24h) elapses, because the sidecar will retry on its own then. |

The `for: 30m` on the quarantine alert is deliberate: the series clears itself
when `RETRY_AFTER` elapses, so a longer `for:` would never fire.

## Runbooks

Common to all of them — where the state lives:

```bash
cd /opt/unbound
docker compose exec -T unbound-autoupdate cat /var/lib/unbound-autoupdate/state.env
```

```
LAST_CONFIG_HASH=aad59c1f…
LAST_IMAGE_DIGEST=esitcparis/unbound-distroless@sha256:0d80…
CYCLES_UP_TO_DATE=1
LAST_CYCLE_STATUS=check_ok
LAST_CYCLE_TS=1789637558
LAST_CYCLE_DURATION=6
CYCLES_CHECK_OK=1
```

`LAST_IMAGE_DIGEST` is the breadcrumb that tells you what was last known
good; no code path reads it back as a control input.

### (a) An update was rolled back

**What you see.** `UnboundAutoupdateRolledBack`, a Healthchecks `/fail`, and
the notification:

> **ROLLBACK performed** — The swap to `<new digest>` failed its post-swap
> validation. Production was rolled back to `<old digest>` and is healthy.
> WARNING: the compose file still declares the failing image. Running
> `docker compose up -d` by hand would redeploy it. The updater will not retry
> before RETRY_AFTER=24h.

If the configuration also changed, the body carries an extra sentence:

> NOTE: the bind-mounted configuration file was NOT reverted — only the image
> was pinned back. Production is recreated on the previous image but is still
> reading the CURRENT configuration on disk. A human must fix or revert that
> file.

**What is quarantined.** Every axis that actually changed in that cycle, and
only those:

| Axis | Keys in `state.env` | Set when |
|---|---|---|
| image | `QUARANTINE_DIGEST`, `QUARANTINE_TS` | the declared digest differed from the running one |
| config | `CONFIG_QUARANTINE_HASH`, `CONFIG_QUARANTINE_TS` | the bind-mount fingerprint differed from the recorded one |

Both are set when both changed. A quarantine holds for `RETRY_AFTER` (default
24h) from its timestamp, and only for that exact value: a **different** digest
or a **different** fingerprint always gets a fresh attempt.

**Do not run `docker compose up -d` by hand.** The rollback pin lives in the
sidecar's own state volume (`/var/lib/unbound-autoupdate/rollback.yml`) and is
passed to Compose for that one invocation only. Your project file still
declares the tag that resolved to the failing image, so a plain `up -d`
redeploys exactly what was just rolled back — with no canary in front of it.

**Steps.**

1. Confirm production is serving: `dig @<host> . SOA +dnssec` shows `ad`, and
   `docker inspect unbound --format '{{.State.Health.Status}}'` is `healthy`.
2. Read why it failed: `docker compose logs --since 2h unbound-autoupdate`.
   The post-swap gate refuses in four ways — the service came back on the same
   container id (Compose did not recreate), the running digest is not the
   declared one, the probe address could not be determined, or the resolver
   did not answer the same validation the canary passed within 45 s.
3. If the configuration changed, fix or revert the file yourself. Nothing
   reverted it.
4. Reproduce without touching production:
   `docker compose run --rm unbound-autoupdate check`. Note that `check` obeys
   nothing about the quarantine — it canaries whatever is declared — so this
   tells you whether the change is now good.
5. Decide before 24h: either leave it (the sidecar retries when the window
   lapses, and will roll back again if it is still broken), or lift the
   quarantine early — runbook (e) — or change what is declared.

### (b) Rollback failed — DNS is down on this host

**What you see.** `UnboundAutoupdateCritical`, and:

> **CRITICAL: rollback failed** — The swap to `<new>` failed AND the rollback
> to `<old>` did not restore a working resolver. DNS is likely down on this
> host. MANUAL INTERVENTION REQUIRED.

**Steps.**

1. Make sure clients are covered: the other host must be answering. Check it
   from a client, not from the broken host.
2. Find a known-good digest: `LAST_IMAGE_DIGEST` in `state.env`, or the
   sidecar's own pin at `/var/lib/unbound-autoupdate/rollback.yml`, or the
   releases page.
3. Stop the updater so it cannot fight you:
   `docker compose stop unbound-autoupdate`.
4. Pin by digest with an override **inside the project directory**, so the
   sidecar can still read it later:

   ```bash
   cat > /opt/unbound/pin.yml <<'EOF'
   services:
     unbound:
       image: esitcparis/unbound-distroless@sha256:<known-good>
   EOF
   docker compose -f docker-compose.yml -f pin.yml up -d --no-deps unbound
   dig @127.0.0.1 . SOA +dnssec | grep -E '^;; flags'
   ```

   Two things follow from `updater/lib/discover.sh`. The override **must** be
   readable inside the sidecar at the same absolute path, or the next cycle
   dies with "compose file … is not readable from inside the sidecar" — that
   is why it goes in `/opt/unbound`. And the sidecar only filters its *own*
   rollback files out of the discovered file list, so once you restart the
   updater it will treat your `pin.yml` as part of the declared project and
   compare against the pinned digest. While the pin is in place, that is
   exactly what you want.
5. Restart the updater: `docker compose start unbound-autoupdate`.
6. When the underlying problem is fixed: delete `pin.yml` and
   `docker compose up -d --no-deps unbound` to hand control back — the
   container must be recreated without the override for Compose to stop
   stamping it on the file list.

### (c) Sidecar self-update failed

**What you see.** `unbound_autoupdate_quarantine_active{axis="self"} 1`, and:

> **sidecar self-update FAILED — rolled back** — The new sidecar image
> `<new>` did not come up. Services `<…>` were pinned back to `<old>`.
> `<new>` is quarantined for RETRY_AFTER=24h. The compose file still declares
> the failing tag.

or, worse:

> **CRITICAL: sidecar self-update FAILED and rollback failed** — Neither
> `<new>` nor `<old>` could be brought up for `<…>`. Automatic updates are
> DOWN on this host. MANUAL INTERVENTION REQUIRED.

**What it means.** The resolver is untouched — self-update runs only at the
*end* of a cycle that already ended `up_to_date` or `updated`. What is broken
is the updater, and possibly `/metrics`. The recreation is done by an
ephemeral helper container started from the new image (a `compose up` issued
from the container being replaced would die mid-way), which moves the
sidecar's own service first and alone, requires it to be running and
un-restarted 30 s later and to be a genuinely new container on the verified
digest, and only then moves the other services on that image.

**Steps.**

1. Is a helper still at work? `docker ps --filter label=unbound-autoupdate.helper=1`.
   Only one runs at a time; a cycle that sees one skips self-update.
   It runs with `--rm`, so capture `docker logs <id>` *while it exists*.
2. Confirm the resolver is fine: `dig`, and the healthcheck.
3. Confirm what the sidecar services are on:
   `docker compose ps` and `docker inspect <container> --format '{{.Image}}'`.
   The helper's pin is at `/var/lib/unbound-autoupdate/self-rollback.yml`.
4. Read `SELF_QUARANTINE_DIGEST` / `SELF_QUARANTINE_TS` in `state.env`. The
   `self` axis is separate on purpose: a broken sidecar release never blocks
   resolver updates.
5. If neither image came up (the critical variant), pin the sidecar services
   by digest with an override exactly as in runbook (b), and remember that
   with the sidecar down nothing is updating or scraping this host.

### (d) Signature verification failed

**What you see.** Cycle status `blocked`, and:

> **signature verification FAILED** — Image `<digest>` is not signed by the
> expected release pipeline. Deployment refused; production untouched.
> Investigate immediately.

or the sidecar variant:

> **sidecar signature verification FAILED** — … an unsigned sidecar image in
> the registry is a supply-chain incident.

**What it means.** `updater/lib/verify.sh` is fail-closed: the image was
pulled but is **never run**, not even as a canary. Production is still on the
old image and still serving. This is a security event.

**Do not bypass it.** Do not set `COSIGN_PUBLIC_KEY` to something more
convenient, do not set `COSIGN_IGNORE_TLOG=1` (key mode only, and it exists
for private mirrors that re-sign, not for silencing a refusal), and do not
loosen `COSIGN_IDENTITY_REGEXP` or `COSIGN_ISSUER`.

**Steps.**

1. Reproduce by hand with the command in *Egress* above, against the exact
   digest from the log. Keep cosign's own stderr — the sidecar prints it.
2. Compare the digest with the one on the releases page for that tag.
3. If the digest is not one this project published, you are looking at a
   registry compromise or an account takeover: freeze updates on every host
   (`SELF_UPDATE=0` and stop the loop, or pin as in runbook (b)) and escalate.
4. If it is legitimate and the signature is simply missing (a release that
   failed to sign), the fix belongs in the release pipeline, not here.

### (e) Lifting a quarantine early

A quarantine is `<value key>` + `<timestamp key>` in `state.env`, and it is
active only while the stored value equals the value being considered **and**
`now - timestamp < RETRY_AFTER`. Four ways out, cheapest first:

1. **Change what is declared.** A different image digest or an edited
   configuration is a different value on that axis and gets a fresh attempt
   immediately. This is usually the right answer: the thing that failed was
   the thing you changed.
2. **Wait.** `RETRY_AFTER` (default 24h) and the next cycle retries by itself.
3. **Shorten `RETRY_AFTER`** in the sidecar's environment and recreate it
   (`docker compose up -d --no-deps unbound-autoupdate`). The window is
   evaluated at check time, so a shorter value lifts every open quarantine at
   once — image, config and self.
4. **Clear the keys.** Stop the sidecar first: a running cycle and the
   self-update helper both rewrite `state.env` under a lock, and an editor
   racing them loses.

   ```bash
   docker compose stop unbound-autoupdate
   docker compose run --rm --entrypoint /bin/sh unbound-autoupdate -c \
     "sed -i -e 's/^QUARANTINE_DIGEST=.*/QUARANTINE_DIGEST=/' \
             -e 's/^QUARANTINE_TS=.*/QUARANTINE_TS=/' \
             /var/lib/unbound-autoupdate/state.env"
   docker compose start unbound-autoupdate
   ```

   Use `CONFIG_QUARANTINE_HASH`/`CONFIG_QUARANTINE_TS` for the config axis and
   `SELF_QUARANTINE_DIGEST`/`SELF_QUARANTINE_TS` for the sidecar axis. An
   empty value or an empty timestamp is what "not quarantined" looks like.

Whatever you clear, the change still goes through the full canary before it
reaches production. Lifting a quarantine does not lower a gate; it only lets
the cycle try again.

### (f) Backing up and restoring the volumes

Two volumes matter. With `name: unbound` in the compose file they are
`unbound_unbound-data` (the DNSSEC trust anchor `root.key` and the root zone
copy) and `unbound_autoupdate-state` (`state.env`, `metrics.prom`, the
quarantine timestamps and the cycle counters). Confirm the names with
`docker volume ls`.

Back up (stop the service first for a consistent copy — the resolver rewrites
`root.key` and `root.zone` on its own schedule). The sidecar image is used
only because it is already on the host and carries a shell, `tar` and `gzip`;
any such image works:

```bash
cd /opt/unbound
docker compose stop unbound
docker run --rm --entrypoint /bin/sh \
  -v unbound_unbound-data:/src:ro -v "$PWD/backup":/backup \
  esitcparis/unbound-autoupdate:1 \
  -c 'tar czf /backup/unbound-data.tgz --numeric-owner -C /src .'
docker compose start unbound

docker run --rm --entrypoint /bin/sh \
  -v unbound_autoupdate-state:/src:ro -v "$PWD/backup":/backup \
  esitcparis/unbound-autoupdate:1 \
  -c 'tar czf /backup/autoupdate-state.tgz --numeric-owner -C /src .'
```

Restore into a fresh volume:

```bash
docker compose down
docker volume create unbound_unbound-data
docker run --rm --entrypoint /bin/sh \
  -v unbound_unbound-data:/dst -v "$PWD/backup":/backup:ro \
  esitcparis/unbound-autoupdate:1 \
  -c 'tar xzf /backup/unbound-data.tgz --numeric-owner -C /dst'
docker compose up -d
```

`--numeric-owner` on both sides is what keeps the files owned by UID/GID
65532, which is the user the resolver runs as. **Verified** by round-tripping
a 65532-owned file through both commands: ownership survived.

Losing `unbound-data` is not fatal — the image ships a trust anchor and a root
zone copy, and Unbound re-primes — but the resolver starts cold and the
sidecar has nothing to clone until the volume exists again. Losing
`autoupdate-state` resets the baseline: the next cycle records a new one
(`baseline recorded`) and the counters and any open quarantine are gone.

### (g) Upgrading the sidecar manually

Normally the sidecar replaces itself. Do it by hand when `SELF_UPDATE=0`, when
the `self` axis is quarantined and you have decided the new image is fine, or
when you are running a locally built image (which never self-updates — there
is no repository digest to compare or roll back to):

```bash
cd /opt/unbound
docker compose pull unbound-autoupdate unbound-metrics
docker compose up -d --no-deps unbound-autoupdate unbound-metrics
docker compose logs --tail 20 unbound-autoupdate
```

`--no-deps` keeps the resolver out of it: the two sidecar services are
recreated, the resolver container is not touched, and DNS keeps answering. The
first cycle after the upgrade reads the same `state.env` from the same volume,
so counters, the baseline and any quarantine survive.

### (h) Rotating a TLS certificate under `tls/`

`config_fingerprint` in `updater/lib/discover.sh` hashes **every** declared
bind mount, not just `unbound.conf`. A mount that is a directory is expanded
with `find -L . \( -type f -o -type l \)`, sorted, and each file contributes
its content hash *and* its path relative to the mount — so a renewed
certificate, a renamed file, and a Let's Encrypt `live/` layout made entirely
of symlinks all move the fingerprint. Two failure modes are deliberately
loud, because a configuration the sidecar cannot read whole is not one it may
hash partially:

- a directory mount that expands to no file at all →
  `config fingerprint: directory mount '<src>' expands to no files`, cycle
  ends `blocked`;
- a dangling symlink → `sha256sum` fails and the cycle ends `blocked`.

So: never empty the directory as an intermediate step, and never leave a
symlink pointing at a file that is not there yet.

```bash
# 1. Put the new material in place atomically (new dir, then swap)
sudo install -d -m 755 /opt/unbound/tls.new
sudo cp fullchain.pem /opt/unbound/tls.new/server.pem
sudo cp privkey.pem   /opt/unbound/tls.new/server.key
sudo mv /opt/unbound/tls /opt/unbound/tls.old && sudo mv /opt/unbound/tls.new /opt/unbound/tls

# 2. Prove it before the loop touches production
docker compose run --rm unbound-autoupdate check && echo OK

# 3. Let the next cycle deploy it (it will: the fingerprint changed), or
#    deploy now — this skips the canary, so only do it after step 2 passed:
#    docker compose up -d --force-recreate --no-deps unbound
```

`--force-recreate` is what the sidecar itself uses on a config-only change:
Compose keys recreation on the service definition, and the *contents* of a
bind-mounted file do not change that, so without it the swap would be a silent
no-op. If the new certificate is bad, the post-swap gate rolls the image back
but **cannot revert your files** — the notification says so, and runbook (a)
step 3 applies.

## Go-live checklist

- [ ] Two hosts, each with the project at the **same absolute path** used on
      both sides of the sidecar's bind mount.
- [ ] Docker Engine + Compose v2 present on both (`docker compose version`).
- [ ] Port 53 free on the address you publish (`ss -lntup 'sport = :53'`).
- [ ] `net.core.rmem_max` / `net.core.wmem_max` ≥ 4194304, persisted in
      `/etc/sysctl.d/`.
- [ ] Host clock synchronised and monitored.
- [ ] Egress open: registry, Sigstore, root servers (TCP+UDP 53), general
      recursion — each tested with the commands above.
- [ ] `unbound.conf` validated with `unbound-checkconf` **using the image that
      will run it**.
- [ ] `.env` present, mode 600, one `HC_URL` **per host**;
      `docker compose config --quiet` passes.
- [ ] `NOTIFY_HOST` set per host, so notifications name the machine.
- [ ] Resolver tag mode chosen deliberately — pinned (A) or tracking `:1` (B)
      — and the same on both hosts.
- [ ] `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, named volume
      on `/var/lib/unbound`, `ulimits.nofile`, memory limit and log rotation
      all present.
- [ ] Both resolvers `healthy`; `dig … . SOA +dnssec` shows `ad` on both.
- [ ] `docker compose logs unbound-autoupdate` shows `baseline recorded` on
      both.
- [ ] `docker compose run --rm unbound-autoupdate check` exits 0 on both.
- [ ] `/metrics` scraped by Prometheus on both; `alerts.yml` loaded
      (`promtool check rules`) and routed to a human.
- [ ] Healthchecks.io checks receiving pings from both hosts, with a grace
      period longer than `INTERVAL + SPLAY`.
- [ ] Host B started ~30 min after host A.
- [ ] Clients (DHCP option 6, `resolv.conf`, or the upstream forwarder) list
      **both** addresses.
- [ ] Failover rehearsed: `docker compose stop unbound` on host A, clients
      still resolve.
- [ ] Volume backups taken and a restore rehearsed — runbook (f).
- [ ] Whoever is on call has read the runbooks and knows the Docker socket
      makes the sidecar root-equivalent on the host.

## Known limits

From `updater/README.md`, and they are design decisions, not gaps to work
around:

- **No Kubernetes.** The sidecar is Compose-native: it reads Compose labels,
  runs `docker compose`, and pins rollbacks with a Compose override. On
  Kubernetes a rollout plus a readiness probe covers the same ground.
- **Nothing outside its own Compose project.** Discovery starts from the
  sidecar's own `com.docker.compose.project` label; containers in another
  project, or outside Compose entirely, are invisible to it.
- **No `network_mode: host` canary.** A host-networked container cannot join
  the canary's isolated network, so a host-networked sidecar refuses up front
  — and a host-networked *resolver* requires a host-networked sidecar to be
  probed at all. The reference project uses the default bridge for this
  reason.
- **Configuration files are never reverted.** A rollback pins the previous
  image; it cannot un-edit a bind-mounted file. When the configuration is what
  changed, the notification says so and a human fixes the file.
- **Locally built sidecar images never self-update.** No repository digest
  means nothing to compare against and nothing to roll back to; the cycle logs
  it and moves on. The same rule applies to the resolver: a locally built
  resolver image is refused rather than guessed at.
- **No Grafana dashboards.** Plain Prometheus exposition; build what you like
  on top of it.

## See also

- [`updater/README.md`](../updater/README.md) — the sidecar in detail:
  variables, per-outcome behaviour, `/metrics`, self-update, the Docker socket
- [`usage.md`](usage.md) — run recipes, Kubernetes, DoT/DoH, tuning,
  troubleshooting
- [`trust.md`](trust.md) — release gates, signing, how to verify an image
- [`observability/`](observability/) — the scrape config and the alert rules
