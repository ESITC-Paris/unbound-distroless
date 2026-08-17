#!/bin/sh
# One-shot installer for the unbound-distroless auto-updater.
# Detects the production setup from the running container, installs
# prerequisites (dig, cosign), the updater script, and its systemd timer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/deploy/install.sh \
#     | sh -s -- --hc-url https://hc-ping.com/YOUR-UUID --mail-to admin@example.org \
#                [--minute 45] [--container unbound]
set -eu

RAW=https://raw.githubusercontent.com/ESITC-Paris/unbound-distroless/main/deploy
CONTAINER=unbound
MINUTE=45
HC_URL=""
MAIL_TO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hc-url)    HC_URL="$2"; shift 2 ;;
    --mail-to)   MAIL_TO="$2"; shift 2 ;;
    --minute)    MINUTE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 \
  || { echo "ERROR: container '$CONTAINER' not found — start unbound first (docker compose up -d)" >&2; exit 1; }

echo "==> Detecting production setup from container '$CONTAINER'"
COMPOSE_FILE=$(docker inspect "$CONTAINER" -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
SERVICE=$(docker inspect "$CONTAINER" -f '{{index .Config.Labels "com.docker.compose.service"}}')
PROD_VOLUME=$(docker inspect "$CONTAINER" -f '{{range .Mounts}}{{if eq .Destination "/var/lib/unbound"}}{{.Name}}{{end}}{{end}}')
CONF_PATH=$(docker inspect "$CONTAINER" -f '{{range .Mounts}}{{if eq .Destination "/etc/unbound/unbound.conf"}}{{.Source}}{{end}}{{end}}')
[ -n "$COMPOSE_FILE" ] || { echo "ERROR: '$CONTAINER' is not managed by docker compose" >&2; exit 1; }
[ -n "$PROD_VOLUME" ]  || { echo "ERROR: no named volume mounted on /var/lib/unbound (required for state persistence and canary cloning)" >&2; exit 1; }
echo "    compose file : $COMPOSE_FILE"
echo "    service      : $SERVICE"
echo "    volume       : $PROD_VOLUME"
echo "    custom conf  : ${CONF_PATH:-(image default)}"
echo "    timer minute : :$MINUTE"

echo "==> Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq bind9-dnsutils curl ca-certificates >/dev/null
if ! command -v cosign >/dev/null; then
  ARCH=$(dpkg --print-architecture)   # amd64 | arm64
  curl -fsSL -o /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${ARCH}"
  chmod +x /usr/local/bin/cosign
fi

echo "==> Installing the updater"
curl -fsSL -o /usr/local/bin/unbound-autoupdate "$RAW/unbound-autoupdate"
chmod 755 /usr/local/bin/unbound-autoupdate
curl -fsSL -o /etc/systemd/system/unbound-autoupdate.service "$RAW/unbound-autoupdate.service"
curl -fsSL -o /etc/systemd/system/unbound-autoupdate.timer   "$RAW/unbound-autoupdate.timer"
sed -i "s/\*:45:00/*:${MINUTE}:00/" /etc/systemd/system/unbound-autoupdate.timer

cat > /etc/unbound-autoupdate.conf <<EOF
COMPOSE_FILE=$COMPOSE_FILE
SERVICE=$SERVICE
PROD_VOLUME=$PROD_VOLUME
CONF_PATH=$CONF_PATH
HC_URL=$HC_URL
MAIL_TO=$MAIL_TO
STRICT_BOGUS_CHECK=0
EOF
chmod 600 /etc/unbound-autoupdate.conf

systemctl daemon-reload
systemctl enable --now unbound-autoupdate.timer >/dev/null 2>&1

echo "==> First run (should log 'up to date' if the container is current)"
systemctl start unbound-autoupdate.service || true
journalctl -u unbound-autoupdate.service -n 8 --no-pager || true

echo "==> Installed. Next runs: hourly at :$MINUTE (journalctl -u unbound-autoupdate.service)"
[ -n "$HC_URL" ] || echo "NOTE: no --hc-url provided — add HC_URL=... to /etc/unbound-autoupdate.conf to enable alerting"
if [ -n "$MAIL_TO" ] && ! command -v sendmail >/dev/null; then
  echo "NOTE: --mail-to is set but no 'sendmail' binary exists on this host."
  echo "      Install and configure a relay, e.g.:  apt install msmtp-mta"
  echo "      then create /etc/msmtprc pointing at your SMTP relay (see deploy/README.md)."
fi
