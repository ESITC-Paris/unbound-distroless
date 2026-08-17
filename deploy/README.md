# Automatic server-side updates

Keeps a production `unbound-distroless` container (run with docker compose,
ports published with `-p 53:53`) automatically up to date, with the same
level of rigor as the publishing pipeline:

1. **Pull** the `1` major tag; exit if the running container already uses it.
2. **cosign verification** — the image must be signed by this repository's
   release workflow. A compromised registry cannot get an image deployed.
3. **Canary** — the new image is started *next to* production with a **clone
   of the production volume** (the live RFC 5011 trust anchor and root zone)
   and the **same configuration file**, on an isolated Docker network.
   Production keeps serving; it is not touched.
4. **Validation** of the canary: healthcheck, UDP and TCP resolution, DNSSEC
   AD flag. Any failure aborts the update — production never saw anything.
5. **Swap** — docker compose recreates the production container on the new
   image (2–4 s restart; clients fail over to the secondary resolver).
6. **Post-swap gate** — health + live DNS validation; on failure the previous
   image is restored automatically (rollback) and the update is aborted.
7. **Notifications** — Healthchecks.io ping only on success (a missing ping
   means a human should look), and optional **e-mail** on every meaningful
   event: successful deployment, signature failure, canary rejection,
   rollback.

A failed update leaves production on the old image; the next hourly run
retries the whole sequence.

## Quick install (one command)

With production already running via docker compose, everything (detection of
the compose file / volume / config, prerequisites, script, timer) is set up
by:

```bash
curl -fsSL https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/deploy/install.sh \
  | sh -s -- --hc-url https://hc-ping.com/YOUR-UUID --mail-to admin@example.org --minute 45
```

Stagger `--minute` across servers (45, 55, ...). E-mail requires a local
`sendmail` (see the e-mail section below); omit `--mail-to` to skip it.

## Manual installation (per server)

Prerequisites:

```bash
apt -y install bind9-dnsutils curl
# cosign (static binary; use cosign-linux-arm64 on ARM servers)
curl -fsSL -o /usr/local/bin/cosign \
  https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
chmod +x /usr/local/bin/cosign
```

Install the script and units (from this directory):

```bash
install -m 755 unbound-autoupdate /usr/local/bin/
install -m 644 unbound-autoupdate.service unbound-autoupdate.timer /etc/systemd/system/
```

Configuration — `/etc/unbound-autoupdate.conf`:

```bash
COMPOSE_FILE=/opt/unbound/docker-compose.yml
SERVICE=unbound
# Find the volume name with:  docker inspect unbound -f '{{range .Mounts}}{{.Name}}{{"\n"}}{{end}}'
PROD_VOLUME=unbound_unbound-data
# Host path of your custom unbound.conf, empty if you use the image default:
CONF_PATH=/opt/unbound/unbound.conf
# Healthchecks.io ping URL for THIS server (one check per server):
HC_URL=https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# Set to 1 only if this network reliably reaches dnssec-failed.org's servers:
STRICT_BOGUS_CHECK=0
```

Enable:

```bash
# Stagger the minute per server first (edit OnCalendar in the timer:
# :45 on resolver 1, :55 on resolver 2, ...)
systemctl daemon-reload
systemctl enable --now unbound-autoupdate.timer
```

## First run and testing

```bash
# Dry run of the whole sequence right now:
systemctl start unbound-autoupdate.service
journalctl -u unbound-autoupdate.service -n 50
```

If the running container is already on the newest image, the run logs
"up to date" and pings Healthchecks — that is the normal hourly outcome.

To watch a real canary+swap without waiting for an upstream release, pin the
production container to an older image first (e.g. `docker tag` an old digest
as the `1` tag locally is *not* enough — instead temporarily change the
compose file to an older `X.Y.Z-rN` tag, `docker compose up -d`, restore the
compose file, then start the service).

## E-mail notifications

The updater sends an e-mail (via the local `sendmail` interface) to `MAIL_TO`
for: successful deployments, signature verification failures, canary
rejections, and rollbacks. On a minimal host, install a relay-only MTA:

```bash
apt -y install msmtp-mta
cat > /etc/msmtprc <<'EOF'
defaults
auth off
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
account default
host smtp.your-relay.example
port 587
from unbound-autoupdate@example.org
EOF
chmod 640 /etc/msmtprc
echo test | sendmail admin@example.org   # verify delivery
```

Adapt `host`/`port`/`auth` to your SMTP relay.

## Healthchecks.io

Create **one check per server** (cron schedule matching the timer's minute,
e.g. `45 * * * *`, timezone Europe/Paris, grace 30 min). The ping is sent
only when the updater finishes successfully, so every failure mode — pull
error, bad signature, failed canary, failed swap, rollback, dead server —
surfaces as a missed ping.

## Behavior reference

| Situation | Result |
|---|---|
| No new image | "up to date", ping, exit 0 |
| New image, bad/absent signature | No deploy, no ping → alert |
| Canary unhealthy or fails DNS validation | Production untouched, no ping → alert; retried next hour |
| Swap succeeds, post-swap validation OK | Production updated, ping |
| Swap fails or post-swap validation fails | Automatic rollback to the previous image, no ping → alert |
| A major version bump (v2) is published | Not deployed (`TAG=1`) — deliberate human decision required |
