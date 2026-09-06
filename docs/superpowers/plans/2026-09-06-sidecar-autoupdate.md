# Sidecar de mise à jour automatique — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Livrer un conteneur sidecar qui met à jour le résolveur `unbound-distroless` d'un projet docker compose, après avoir validé la nouvelle image contre la configuration réelle de l'utilisateur et un clone de l'état de production.

**Architecture:** Le sidecar découvre sa cible par les labels Compose, compare l'état déclaré (`docker compose config` + `compose pull`) à l'état en service (`docker inspect`), vérifie la signature cosign, valide en canari sur réseau isolé, puis swappe par `docker compose up -d --no-deps`. Échec post-swap → rollback par override épinglé au digest + quarantaine.

**Tech Stack:** bash, docker CLI + plugin compose, cosign v2.6.5, bind-tools, Alpine.

**Spec:** `docs/superpowers/specs/2026-09-06-sidecar-autoupdate-design.md`

## Global Constraints

- Shell : `bash`, `set -euo pipefail` en tête de chaque exécutable. Tout doit passer `shellcheck -S warning`.
- Prose et commentaires du code : **anglais** (convention du dépôt). Ce plan et la spec sont en français.
- Aucune action hors périmètre : le sidecar ne touche qu'aux objets qu'il crée et au seul service découvert. **Jamais** de `docker image prune` / `docker system prune`.
- `docker compose up` porte **toujours** `--no-deps` : sans lui, Compose recrée aussi le sidecar, qui se tue en plein cycle.
- Toute image tierce est épinglée par digest, comme le reste du dépôt.
- Aucun `${{ }}` dans un corps `run:` de workflow — uniquement via `env:`.
- Actions GitHub épinglées au SHA complet, avec le tag en commentaire.
- Chemins : `STATE_DIR=/var/lib/unbound-autoupdate`, libs dans `/usr/local/lib/unbound-autoupdate/`.
- Le state du sidecar est un fichier `KEY=VALUE` sans commentaire (sourcé directement).

### Correction de conception par rapport à la spec

La spec §5.1 fait lire les montages de configuration depuis `.Mounts` du conteneur **en marche**. C'est faux : le canari doit valider la configuration **que Compose va déployer**. Si l'utilisateur change à la fois l'image et le chemin de sa conf, le canari validerait l'ancienne conf et déclarerait bon un déploiement qui casse.

**Règle appliquée dans tout ce plan :** l'état *déclaré* (image, montages de conf) vient de `docker compose config --format json`. L'état *en service* (digest courant, réseau) vient de `docker inspect`. Symétrique au traitement de l'image.

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `updater/Dockerfile` | Image Alpine + docker-cli + compose + cosign + bind-tools |
| `updater/lib/log.sh` | Logs structurés, notifications Healthchecks et webhook |
| `updater/lib/state.sh` | État persistant, verrou, quarantaine |
| `updater/lib/discover.sh` | Découverte Compose : état déclaré vs état en service |
| `updater/lib/validate.sh` | Sonde de disponibilité + critères DNS |
| `updater/lib/canary.sh` | Pré-vol checkconf + cycle de vie du canari |
| `updater/unbound-autoupdate` | Orchestrateur du cycle |
| `updater/entrypoint.sh` | Modes `loop` / `once` / `check`, intervalle et dispersion |
| `updater/VERSION` | Semver du sidecar |
| `updater/compose.snippet.yml` | Extrait prêt à coller |
| `updater/README.md` | Documentation utilisateur |
| `tests/updater/lib.sh` | Fabrique de fixtures compose + assertions |
| `tests/updater.sh` | Suite d'intégration T1–T8 |

---

### Task 1: Image, logs, état

**Files:**
- Create: `updater/Dockerfile`, `updater/VERSION`, `updater/lib/log.sh`, `updater/lib/state.sh`, `updater/.dockerignore`
- Test: `tests/updater/lib.sh`, `tests/updater.sh` (squelette + T0)

**Interfaces:**
- Consumes: rien.
- Produces:
  - `log_info <msg>` / `log_warn <msg>` / `log_error <msg>` / `log_die <msg>` (die = error + `exit 1`)
  - `notify <event> <subject> <body>` — `event` ∈ `updated|blocked|rollback|critical|skipped|baseline`
  - `hc_start` / `hc_success` / `hc_fail <msg>`
  - `state_init` / `state_get <key>` / `state_set <key> <value>`
  - `quarantine_set <digest>` / `quarantine_active <digest>` (0 = actif) / `quarantine_clear`
  - `to_seconds <duration>` — accepte `45s`, `30m`, `1h`, `2d`, ou un entier nu (secondes)
  - Variables d'env : `STATE_DIR`, `HC_URL`, `WEBHOOK_URL`, `RETRY_AFTER`

- [ ] **Step 1: Résoudre les digests des images de base**

```bash
docker buildx imagetools inspect alpine:3.22 --format '{{println .Manifest.Digest}}' | head -1
docker buildx imagetools inspect ghcr.io/sigstore/cosign/cosign:v2.6.5 --format '{{println .Manifest.Digest}}' | head -1
```

Coller les deux valeurs dans les `ARG` du Dockerfile de l'étape 3. Ne pas inventer de digest : si une commande échoue, s'arrêter et le signaler.

- [ ] **Step 2: Écrire le test T0 qui échoue**

`tests/updater.sh` :

```bash
#!/usr/bin/env bash
# Integration suite for the unbound-autoupdate sidecar.
# Usage: tests/updater.sh [image-tag]   (default: unbound-autoupdate:test)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/updater/lib.sh
. "$HERE/updater/lib.sh"

UPDATER_IMAGE="${1:-unbound-autoupdate:test}"

t0_image_sane() {
  docker image inspect "$UPDATER_IMAGE" >/dev/null 2>&1 || fail "image $UPDATER_IMAGE not built"
  for b in docker cosign dig bash flock; do
    docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c "command -v $b" >/dev/null \
      || fail "missing binary in image: $b"
  done
  docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c 'docker compose version' >/dev/null \
    || fail "docker compose plugin missing"
  docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c 'cosign version' >/dev/null \
    || fail "cosign not runnable"
  pass "image contains docker+compose+cosign+dig+bash+flock"
}

t0_state_unit() {
  local out
  out=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st RETRY_AFTER=1h
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    state_init
    [ -z "$(state_get LAST_IMAGE_DIGEST)" ] || { echo "expected empty"; exit 1; }
    state_set LAST_IMAGE_DIGEST "repo@sha256:aaa"
    [ "$(state_get LAST_IMAGE_DIGEST)" = "repo@sha256:aaa" ] || { echo "roundtrip failed"; exit 1; }
    state_set LAST_IMAGE_DIGEST "repo@sha256:bbb"
    [ "$(state_get LAST_IMAGE_DIGEST)" = "repo@sha256:bbb" ] || { echo "overwrite failed"; exit 1; }
    quarantine_active "repo@sha256:ccc" && { echo "should not be quarantined"; exit 1; }
    quarantine_set "repo@sha256:ccc"
    quarantine_active "repo@sha256:ccc" || { echo "should be quarantined"; exit 1; }
    quarantine_active "repo@sha256:ddd" && { echo "other digest must not be quarantined"; exit 1; }
    quarantine_clear
    quarantine_active "repo@sha256:ccc" && { echo "clear failed"; exit 1; }
    [ "$(to_seconds 45s)" = 45 ] && [ "$(to_seconds 30m)" = 1800 ] \
      && [ "$(to_seconds 1h)" = 3600 ] && [ "$(to_seconds 2d)" = 172800 ] \
      && [ "$(to_seconds 90)" = 90 ] || { echo "to_seconds failed"; exit 1; }
    echo OK') || fail "state unit failed: $out"
  [ "${out##*$'\n'}" = OK ] || fail "state unit did not print OK: $out"
  pass "state, quarantine and to_seconds behave"
}

t0_image_sane
t0_state_unit
echo "ALL UPDATER TESTS PASSED"
```

`tests/updater/lib.sh` :

```bash
#!/usr/bin/env bash
# Shared helpers for the updater integration suite.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
info() { echo "---- $*"; }
```

- [ ] **Step 3: Lancer le test, vérifier qu'il échoue**

```bash
bash tests/updater.sh
```
Attendu : `FAIL: image unbound-autoupdate:test not built`.

- [ ] **Step 4: Écrire `updater/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

# Digests resolved in Step 1 — replace both placeholders with the real values.
ARG ALPINE_BASE=alpine:3.22@sha256:PASTE_ALPINE_DIGEST
ARG COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5@sha256:PASTE_COSIGN_DIGEST

FROM ${COSIGN_IMAGE} AS cosign

FROM ${ALPINE_BASE}
ARG UPDATER_VERSION=dev
LABEL org.opencontainers.image.title="unbound-autoupdate" \
      org.opencontainers.image.description="Canary-tested automatic updater for unbound-distroless" \
      org.opencontainers.image.source="https://github.com/ESITC-Paris/unbound-distroless" \
      org.opencontainers.image.version="${UPDATER_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="ESITC Paris"

# bash: arrays and `local -n` are used throughout. util-linux: flock.
# tini: the loop mode must forward SIGTERM so `docker compose down` is prompt.
RUN apk add --no-cache \
      bash docker-cli docker-cli-compose bind-tools curl ca-certificates \
      coreutils util-linux tini jq

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign

COPY lib/ /usr/local/lib/unbound-autoupdate/
COPY unbound-autoupdate entrypoint.sh /usr/local/bin/
COPY VERSION /usr/local/lib/unbound-autoupdate/VERSION
RUN chmod 0755 /usr/local/bin/unbound-autoupdate /usr/local/bin/entrypoint.sh

# The container runs as root on purpose: it needs the Docker socket, which is
# root-equivalent anyway. Documented in updater/README.md rather than hidden.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

`updater/VERSION` : `1.0.0`

`updater/.dockerignore` :
```
README.md
compose.snippet.yml
```

- [ ] **Step 5: Écrire `updater/lib/log.sh`**

```bash
#!/usr/bin/env bash
# Structured logging and best-effort notifications. Never fails the caller.

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf 'ts=%s level=%s msg=%s\n' "$(_ts)" "$1" "$(printf '%q' "$2")"; }

log_info()  { _log info  "$1"; }
log_warn()  { _log warn  "$1"; }
log_error() { _log error "$1" >&2; }
log_die()   { log_error "$1"; exit 1; }

# notify <event> <subject> <body>
notify() {
  local event="$1" subject="$2" body="$3"
  printf 'ts=%s level=notice event=%s subject=%s\n' "$(_ts)" "$event" "$(printf '%q' "$subject")"
  [ -n "${WEBHOOK_URL:-}" ] || return 0
  local payload
  payload=$(jq -nc --arg e "$event" --arg h "$(hostname)" --arg s "$subject" --arg b "$body" \
    '{event:$e, host:$h, subject:$s, body:$b, text:("[unbound-autoupdate] " + $h + " — " + $s + "\n" + $b)}')
  curl -fsS -m 15 --retry 2 -H 'Content-Type: application/json' \
    -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 \
    || log_warn "webhook delivery failed"
}

_hc() {  # _hc <suffix> [body]
  [ -n "${HC_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 2 --data-raw "${2:-}" "${HC_URL}${1}" >/dev/null 2>&1 \
    || log_warn "healthchecks ping failed"
}
hc_start()   { _hc /start; }
hc_success() { _hc ""; }
hc_fail()    { _hc /fail "${1:-}"; }
```

- [ ] **Step 6: Écrire `updater/lib/state.sh`**

```bash
#!/usr/bin/env bash
# Persistent state, advisory lock and digest quarantine.
# STATE_DIR must be a writable named volume so state survives recreation.

STATE_DIR="${STATE_DIR:-/var/lib/unbound-autoupdate}"
STATE_FILE="$STATE_DIR/state.env"
LOCK_FILE="$STATE_DIR/lock"

state_init() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
}

# state_get <key> — echoes the value, or nothing when unset.
state_get() {
  local line
  line=$(grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null) || return 0
  printf '%s\n' "${line#*=}"
}

# state_set <key> <value> — atomic replace-or-append.
state_set() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
  grep -v "^$key=" "$STATE_FILE" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

quarantine_set() {
  state_set QUARANTINE_DIGEST "$1"
  state_set QUARANTINE_TS "$(date -u +%s)"
}

quarantine_clear() {
  state_set QUARANTINE_DIGEST ""
  state_set QUARANTINE_TS ""
}

# quarantine_active <digest> — returns 0 when this digest is quarantined and
# the RETRY_AFTER window has not elapsed. A different digest is never
# quarantined: a newly published image deserves a fresh attempt.
quarantine_active() {
  local d ts now
  d=$(state_get QUARANTINE_DIGEST)
  [ -n "$d" ] && [ "$d" = "$1" ] || return 1
  ts=$(state_get QUARANTINE_TS); [ -n "$ts" ] || return 1
  now=$(date -u +%s)
  [ $(( now - ts )) -lt "$(to_seconds "${RETRY_AFTER:-24h}")" ]
}

# to_seconds <duration> — 45s | 30m | 1h | 2d | bare integer (seconds).
to_seconds() {
  local v="$1" n u
  n="${v%[smhd]}"; u="${v##"$n"}"
  case "$n" in ''|*[!0-9]*) log_die "invalid duration: $v";; esac
  case "$u" in
    ''|s) printf '%s\n' "$n" ;;
    m)    printf '%s\n' $(( n * 60 )) ;;
    h)    printf '%s\n' $(( n * 3600 )) ;;
    d)    printf '%s\n' $(( n * 86400 )) ;;
    *)    log_die "invalid duration suffix: $v" ;;
  esac
}
```

- [ ] **Step 7: Construire l'image et relancer le test**

```bash
docker build -t unbound-autoupdate:test updater/
bash tests/updater.sh
```
Attendu : `PASS: image contains ...`, `PASS: state, quarantine and to_seconds behave`, `ALL UPDATER TESTS PASSED`.

- [ ] **Step 8: shellcheck**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  -S warning updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
```
Attendu : aucune sortie.

- [ ] **Step 9: Commit**

```bash
git add updater/ tests/updater.sh tests/updater/lib.sh
git commit -m "feat(updater): sidecar image skeleton with logging and state"
```

---

### Task 2: Découverte Compose

**Files:**
- Create: `updater/lib/discover.sh`
- Modify: `tests/updater.sh` (ajouter T-discover), `tests/updater/lib.sh` (fabrique de fixtures)

**Interfaces:**
- Consumes: `log_die`, `log_info`, `log_warn` (Task 1).
- Produces (variables globales positionnées par `discover_target`) :
  - `SELF_ID`, `SELF_IMAGE`
  - `TARGET_CONTAINER`, `TARGET_SERVICE`, `COMPOSE_PROJECT`, `COMPOSE_WORKDIR`
  - `COMPOSE_FILE_ARGS` (tableau bash `-f a -f b`)
  - `DECLARED_IMAGE_REF` — la référence écrite dans le compose file
  - `DECLARED_BIND_MOUNTS` (tableau bash `-v src:dst:ro …`) — montages **déclarés** sous `/etc/unbound`
  - `TARGET_STATE_VOLUME` — nom du volume monté sur `/var/lib/unbound`
- Produces (fonctions) :
  - `compose <args…>` — invoque `docker compose` avec projet, `--project-directory` et `-f`, plus `$COMPOSE_EXTRA_FILE` si défini
  - `running_digest` — `repo@sha256:…` du conteneur en service
  - `declared_digest` — `repo@sha256:…` de l'image déclarée, après `compose pull`
  - `config_fingerprint` — sha256 des contenus de `DECLARED_BIND_MOUNTS`
  - `image_version_label <ref>` — valeur de `org.opencontainers.image.version`, vide si absente
  - `target_probe_ip` — IP à interroger pour la production (gère `network_mode: host`)

- [ ] **Step 1: Étendre `tests/updater/lib.sh` avec la fabrique de fixtures**

```bash
# fixture_create <dir> <image-ref> [host-udp-port] — writes a compose project
# and starts it. When a port is given the resolver publishes it on loopback,
# which is the one axis on which a canary and production genuinely differ.
# The project dir is bind-mounted into the sidecar at the SAME absolute path,
# which is what makes Compose's relative bind-mount resolution line up.
fixture_create() {
  local dir="$1" ref="$2" port="${3:-}" ports=""
  [ -n "$port" ] && ports=$'\n    ports:\n      - "127.0.0.1:'"$port"$':53/udp"'
  mkdir -p "$dir"
  cp "$REPO_ROOT/unbound.conf" "$dir/unbound.conf"
  cat > "$dir/docker-compose.yml" <<YML
services:
  unbound:
    image: $ref$ports
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    volumes:
      - state:/var/lib/unbound
      - ./unbound.conf:/etc/unbound/unbound.conf:ro
  updater:
    image: $UPDATER_IMAGE
    entrypoint: ["sleep", "infinity"]
    environment:
      STATE_DIR: /var/lib/unbound-autoupdate
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $dir:$dir:ro
      - ustate:/var/lib/unbound-autoupdate
volumes:
  state:
  ustate:
YML
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" up -d ) >/dev/null
}

fixture_project() { basename "$1" | tr -cd 'a-z0-9'; }

fixture_destroy() {
  local dir="$1"
  ( cd "$dir" && docker compose -p "$(fixture_project "$dir")" down -v --remove-orphans ) >/dev/null 2>&1 || true
  rm -rf "$dir"
}

# fixture_set_image <dir> <ref> — rewrites the declared image in place,
# simulating a new release becoming available.
fixture_set_image() {
  sed -i.bak "s|^    image: .*unbound-distroless.*|    image: $2|" "$1/docker-compose.yml"
  rm -f "$1/docker-compose.yml.bak"
}

# updater_exec <dir> <command…> — runs a command inside the fixture's sidecar.
updater_exec() {
  local dir="$1"; shift
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
    -f "$dir/docker-compose.yml" exec -T updater "$@"
}

# running_ref <dir> — the image digest the resolver container actually runs.
running_ref() {
  local cid
  cid=$(docker compose -p "$(fixture_project "$1")" --project-directory "$1" \
        -f "$1/docker-compose.yml" ps -q unbound)
  docker inspect "$cid" --format '{{.Image}}'
}
```

Ajouter en tête de `tests/updater/lib.sh` :

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATER_IMAGE="${UPDATER_IMAGE:-unbound-autoupdate:test}"
TEST_TMPDIR="${TEST_TMPDIR:-/tmp}"
```

`sed -i.bak` plutôt que `sed -i` : la suite doit tourner aussi bien sur le macOS de développement que sur les runners GNU.

- [ ] **Step 2: Écrire le test de découverte qui échoue**

Ajouter à `tests/updater.sh` :

```bash
t_discover() {
  local dir="$TEST_TMPDIR/upd-discover-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    discover_target
    echo "service=$TARGET_SERVICE"
    echo "workdir=$COMPOSE_WORKDIR"
    echo "declared=$DECLARED_IMAGE_REF"
    echo "volume=$TARGET_STATE_VOLUME"
    echo "confmounts=${DECLARED_BIND_MOUNTS[*]}"
    echo "fp=$(config_fingerprint)"
    echo "running=$(running_digest)"') || fail "discover_target failed: $out"

  grep -q '^service=unbound$'                       <<<"$out" || fail "bad service: $out"
  grep -q "^workdir=$dir\$"                         <<<"$out" || fail "bad workdir: $out"
  grep -q '^declared=esitcparis/unbound-distroless:1$' <<<"$out" || fail "bad declared ref: $out"
  grep -q '^volume=.*state$'                        <<<"$out" || fail "bad state volume: $out"
  grep -q "confmounts=.*$dir/unbound.conf:/etc/unbound/unbound.conf" <<<"$out" || fail "conf mount not discovered: $out"
  grep -qE '^fp=[0-9a-f]{64}$'                      <<<"$out" || fail "bad fingerprint: $out"
  grep -qE '^running=esitcparis/unbound-distroless@sha256:[0-9a-f]{64}$' <<<"$out" || fail "bad running digest: $out"
  pass "discovery derives service, workdir, declared ref, volume, conf mounts"
}
```

- [ ] **Step 3: Lancer, vérifier l'échec**

```bash
bash tests/updater.sh
```
Attendu : échec avec `discover.sh: No such file or directory`.

- [ ] **Step 4: Écrire `updater/lib/discover.sh`**

```bash
#!/usr/bin/env bash
# Compose discovery. Declared state comes from `docker compose config`;
# running state comes from `docker inspect`. Keeping those two sources
# separate is the whole point: the canary must test what Compose WILL
# deploy, not what happens to be mounted right now.

# discover_self_id — the sidecar's own container id.
discover_self_id() {
  local id
  id=$(grep -oE '/(docker|containers)/[0-9a-f]{64}' /proc/self/mountinfo 2>/dev/null \
       | grep -oE '[0-9a-f]{64}' | head -1) || true
  [ -n "$id" ] || id=$(docker ps --no-trunc --format '{{.ID}}' \
       | grep -m1 "^$(cat /etc/hostname)") || true
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

_label() { docker inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null; }

discover_target() {
  SELF_ID=$(discover_self_id) || log_die "cannot determine my own container id — is /var/run/docker.sock mounted?"
  SELF_IMAGE=$(docker inspect "$SELF_ID" --format '{{.Config.Image}}')

  COMPOSE_PROJECT=$(_label "$SELF_ID" com.docker.compose.project)
  [ -n "$COMPOSE_PROJECT" ] || log_die "this container is not managed by docker compose"

  # Candidate = sibling service in the same project whose image repository
  # mentions unbound. Deliberately loose so forks and private mirrors work.
  local candidates=() cid
  while read -r cid; do
    [ "$cid" = "$SELF_ID" ] && continue
    case "$(docker inspect "$cid" --format '{{.Config.Image}}')" in
      *unbound*) candidates+=("$cid") ;;
    esac
  done < <(docker ps --no-trunc --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{.ID}}')

  if [ -n "${TARGET_SERVICE:-}" ]; then
    TARGET_CONTAINER=$(docker ps --no-trunc \
      --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
      --filter "label=com.docker.compose.service=$TARGET_SERVICE" --format '{{.ID}}' | head -1)
    [ -n "$TARGET_CONTAINER" ] || log_die "TARGET_SERVICE='$TARGET_SERVICE' not found in project '$COMPOSE_PROJECT'"
  elif [ "${#candidates[@]}" -eq 1 ]; then
    TARGET_CONTAINER="${candidates[0]}"
  else
    local names=""
    for cid in "${candidates[@]:-}"; do names="$names $(_label "$cid" com.docker.compose.service)"; done
    log_die "discovery found ${#candidates[@]} candidate services (${names:-none}) — set TARGET_SERVICE explicitly"
  fi

  TARGET_SERVICE=$(_label "$TARGET_CONTAINER" com.docker.compose.service)
  COMPOSE_WORKDIR=$(_label "$TARGET_CONTAINER" com.docker.compose.project.working_dir)
  local files; files=$(_label "$TARGET_CONTAINER" com.docker.compose.project.config_files)
  [ -n "$files" ] && [ -n "$COMPOSE_WORKDIR" ] || log_die "target container carries no compose file labels"

  COMPOSE_FILE_ARGS=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Compose records relative paths when invoked with one; resolve against workdir.
    case "$f" in /*) : ;; *) f="$COMPOSE_WORKDIR/$f" ;; esac
    [ -r "$f" ] || log_die "compose file '$f' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path"
    COMPOSE_FILE_ARGS+=(-f "$f")
  done < <(printf '%s' "$files" | tr ',' '\n')

  _read_declared
  _read_running_mounts
}

# compose <args…> — always scoped to the discovered project.
compose() {
  local args=(-p "$COMPOSE_PROJECT" --project-directory "$COMPOSE_WORKDIR" "${COMPOSE_FILE_ARGS[@]}")
  [ -n "${COMPOSE_EXTRA_FILE:-}" ] && args+=(-f "$COMPOSE_EXTRA_FILE")
  docker compose "${args[@]}" "$@"
}

# _read_declared — DECLARED_IMAGE_REF and DECLARED_BIND_MOUNTS, from the
# compose project itself rather than from the running container.
_read_declared() {
  local cfg
  cfg=$(compose config --format json) || log_die "docker compose config failed — the project cannot be resolved from inside the sidecar"

  DECLARED_IMAGE_REF=$(jq -r --arg s "$TARGET_SERVICE" '.services[$s].image // empty' <<<"$cfg")
  [ -n "$DECLARED_IMAGE_REF" ] || log_die "service '$TARGET_SERVICE' declares no image"

  DECLARED_BIND_MOUNTS=()
  local src dst
  while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] || continue
    [ -r "$src" ] || log_die "declared config file '$src' is not readable from inside the sidecar — it must be mounted read-only at the same absolute path"
    DECLARED_BIND_MOUNTS+=(-v "$src:$dst:ro")
  done < <(jq -r --arg s "$TARGET_SERVICE" '
      .services[$s].volumes // []
      | .[] | select(.type == "bind")
      | select(.target | startswith("/etc/unbound"))
      | [.source, .target] | @tsv' <<<"$cfg")
}

_read_running_mounts() {
  TARGET_STATE_VOLUME=$(docker inspect "$TARGET_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/unbound"}}{{.Name}}{{end}}{{end}}')
  [ -n "$TARGET_STATE_VOLUME" ] || log_die "service '$TARGET_SERVICE' has no named volume on /var/lib/unbound — required to persist the DNSSEC trust anchor and to clone state for the canary"
}

# running_digest — repo@sha256:… actually in service.
running_digest() {
  local img rd
  img=$(docker inspect "$TARGET_CONTAINER" --format '{{.Image}}')
  rd=$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')
  [ -n "$rd" ] || log_die "the running image has no repository digest (locally built?) — refusing to guess whether an update is due"
  printf '%s\n' "$rd"
}

# declared_digest — repo@sha256:… of the declared image. Caller must have
# pulled first. Pulling before verifying is safe: pulling is not running.
declared_digest() {
  local rd
  rd=$(docker image inspect "$DECLARED_IMAGE_REF" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null)
  [ -n "$rd" ] || log_die "declared image '$DECLARED_IMAGE_REF' has no repository digest after pull"
  printf '%s\n' "$rd"
}

# config_fingerprint — one sha256 over every declared config file, ordered.
config_fingerprint() {
  local src paths=()
  local i
  for (( i = 0; i < ${#DECLARED_BIND_MOUNTS[@]}; i++ )); do
    [ "${DECLARED_BIND_MOUNTS[$i]}" = "-v" ] || continue
    src="${DECLARED_BIND_MOUNTS[$((i+1))]%%:*}"
    paths+=("$src")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    printf '%s\n' "$(printf '' | sha256sum | cut -d' ' -f1)"
    return 0
  fi
  printf '%s\n' "$(printf '%s\n' "${paths[@]}" | sort | xargs cat | sha256sum | cut -d' ' -f1)"
}

image_version_label() {
  docker image inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}

# target_probe_ip — the address to send validation queries to.
target_probe_ip() {
  local mode ip
  mode=$(docker inspect "$TARGET_CONTAINER" --format '{{.HostConfig.NetworkMode}}')
  if [ "$mode" = host ]; then
    [ "$(docker inspect "$SELF_ID" --format '{{.HostConfig.NetworkMode}}')" = host ] \
      || log_die "the resolver uses network_mode: host — the updater must declare network_mode: host as well so it can reach it"
    printf '127.0.0.1\n'; return 0
  fi
  ip=$(docker inspect "$TARGET_CONTAINER" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | awk '{print $1}')
  [ -n "$ip" ] || log_die "cannot determine the resolver's container IP"
  printf '%s\n' "$ip"
}
```

- [ ] **Step 5: Reconstruire, relancer**

```bash
docker build -t unbound-autoupdate:test updater/
bash tests/updater.sh
```
Attendu : `PASS: discovery derives service, workdir, declared ref, volume, conf mounts`.

- [ ] **Step 6: shellcheck puis commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
git add updater/lib/discover.sh tests/
git commit -m "feat(updater): compose discovery from declared and running state"
```

---

### Task 3: Validation DNS

**Files:**
- Create: `updater/lib/validate.sh`
- Modify: `tests/updater.sh`

**Interfaces:**
- Consumes: `log_info`, `log_warn`, `log_die` (Task 1).
- Produces:
  - `wait_resolver <ip> [timeout_seconds]` — 0 dès que le résolveur répond ; défaut 60 s
  - `validate_resolver <ip>` — 0 si les critères passent, 1 sinon (raison journalisée)
  - Variables : `VALIDATE_DOMAIN` (défaut `example.com`), `STRICT_BOGUS_CHECK` (défaut `0`)

- [ ] **Step 1: Écrire le test qui échoue**

```bash
t_validate() {
  local dir="$TEST_TMPDIR/upd-validate-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    discover_target
    ip=$(target_probe_ip)
    wait_resolver "$ip" 90    || { echo "readiness failed"; exit 1; }
    validate_resolver "$ip"   || { echo "validation failed"; exit 1; }
    validate_resolver 192.0.2.1 && { echo "dead address must not validate"; exit 1; }
    echo OK') || fail "validation failed: $out"
  grep -q '^OK$' <<<"$out" || fail "validate did not reach OK: $out"
  pass "readiness probe and DNS criteria (UDP, TCP, AD flag); dead address rejected"
}
```

`192.0.2.1` est du TEST-NET-1 (RFC 5737) : garanti non routable, donc l'assertion négative ne dépend d'aucune particularité du réseau du runner.

- [ ] **Step 2: Lancer, vérifier l'échec**

```bash
bash tests/updater.sh
```
Attendu : `validate.sh: No such file or directory`.

- [ ] **Step 3: Écrire `updater/lib/validate.sh`**

```bash
#!/usr/bin/env bash
# Resolver readiness and correctness checks. The SAME function gates the
# canary and the post-swap production container: whatever was judged good on
# the canary is exactly what production is held to.

VALIDATE_DOMAIN="${VALIDATE_DOMAIN:-example.com}"
STRICT_BOGUS_CHECK="${STRICT_BOGUS_CHECK:-0}"

# wait_resolver <ip> [timeout_seconds]
# A DNS query of our own, NOT the image HEALTHCHECK: that healthcheck talks to
# the unix control socket, which a user's configuration may legitimately
# replace with a TCP/TLS remote-control — and a resolver that answers queries
# is exactly what we care about.
wait_resolver() {
  local ip="$1" timeout="${2:-60}" deadline
  deadline=$(( $(date -u +%s) + timeout ))
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    if dig +time=2 +tries=1 "@$ip" "$VALIDATE_DOMAIN" A 2>/dev/null | grep -q 'status: NOERROR'; then
      return 0
    fi
    sleep 2
  done
  log_error "resolver at $ip did not answer within ${timeout}s"
  return 1
}

# _retry_dig <expected-ERE> <dig args…> — a cold resolver can transiently
# SERVFAIL while priming; a persistent failure still fails the gate.
_retry_dig() {
  local expect="$1" out; shift
  local i
  for i in 1 2 3 4; do
    out=$(dig +time=5 +tries=2 "$@" 2>/dev/null) || out=""
    grep -qE "$expect" <<<"$out" && return 0
    sleep 5
  done
  return 1
}

# validate_resolver <ip>
validate_resolver() {
  local ip="$1"
  _retry_dig 'status: NOERROR'    "@$ip" "$VALIDATE_DOMAIN" A      || { log_error "validation: UDP resolution failed"; return 1; }
  _retry_dig 'status: NOERROR'    "@$ip" +tcp "$VALIDATE_DOMAIN" A || { log_error "validation: TCP resolution failed"; return 1; }
  _retry_dig '^;; flags:.* ad'    "@$ip" . SOA +dnssec             || { log_error "validation: no AD flag on the root SOA — DNSSEC validation is not working"; return 1; }
  if [ "$STRICT_BOGUS_CHECK" = 1 ]; then
    _retry_dig 'status: SERVFAIL' "@$ip" dnssec-failed.org A       || { log_error "validation: a deliberately bogus domain was not rejected"; return 1; }
  fi
  return 0
}
```

- [ ] **Step 4: Reconstruire, relancer, vérifier le PASS**

```bash
docker build -t unbound-autoupdate:test updater/ && bash tests/updater.sh
```

- [ ] **Step 5: shellcheck puis commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
git add updater/lib/validate.sh tests/updater.sh
git commit -m "feat(updater): shared DNS readiness and validation gate"
```

---

### Task 4: Pré-vol et canari — tests T4 et T5

**Files:**
- Create: `updater/lib/canary.sh`
- Modify: `tests/updater.sh`

**Interfaces:**
- Consumes: `discover_target` et ses globales, `wait_resolver`, `validate_resolver`, `log_*`.
- Produces:
  - `preflight_checkconf <image_ref>` — 0 si la conf déclarée est valide pour cette image ; l'erreur d'Unbound est journalisée telle quelle
  - `canary_up <image_ref>` — positionne `CANARY_IP`
  - `canary_down` — idempotent, détache le sidecar du réseau
  - `_canary_names` — dérive `CANARY_NAME`, `CANARY_VOL`, `CANARY_NET` de `$COMPOSE_PROJECT` **au moment de l'appel**, jamais au source

- [ ] **Step 1: Écrire T4 et T5 (échouent)**

```bash
t4_invalid_conf_rejected() {
  local dir="$TEST_TMPDIR/upd-t4-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local before; before=$(running_ref "$dir")
  printf 'server:\n  this-is-not-a-directive: 1\n' > "$dir/unbound.conf"
  local out rc=0
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    preflight_checkconf "$DECLARED_IMAGE_REF"' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "preflight accepted an invalid configuration"
  grep -qi 'unknown keyword\|error' <<<"$out" || fail "preflight did not surface unbound's own error: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "production container was touched by a failed preflight"
  pass "T4: invalid configuration rejected in preflight, production untouched"
}

t5_healthcheck_breaking_conf() {
  local dir="$TEST_TMPDIR/upd-t5-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  # The exact trap in this project's own unbound.conf.local: remote-control
  # over TCP/TLS, whose key and certificate files are deliberately absent
  # from the image.
  cat >> "$dir/unbound.conf" <<'CONF'
remote-control:
  control-enable: yes
  control-interface: 127.0.0.1
  control-port: 8953
  server-key-file: "/etc/unbound/unbound_server.key"
  server-cert-file: "/etc/unbound/unbound_server.pem"
  control-key-file: "/etc/unbound/unbound_control.key"
  control-cert-file: "/etc/unbound/unbound_control.pem"
CONF
  local out rc=0 start elapsed
  start=$(date -u +%s)
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    preflight_checkconf "$DECLARED_IMAGE_REF"' 2>&1) || rc=$?
  elapsed=$(( $(date -u +%s) - start ))
  [ "$rc" -ne 0 ] || fail "preflight accepted a config whose control files do not exist"
  grep -q 'unbound_server.key' <<<"$out" || fail "preflight did not name the missing file: $out"
  [ "$elapsed" -lt 30 ] || fail "preflight took ${elapsed}s — it timed out instead of reporting precisely"
  pass "T5: control-file trap reported precisely by checkconf, not as a timeout"
}

t_canary_lifecycle() {
  local dir="$TEST_TMPDIR/upd-canary-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "esitcparis/unbound-distroless:1"
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    set -euo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    . /usr/local/lib/unbound-autoupdate/canary.sh
    discover_target
    trap canary_down EXIT
    canary_up "$DECLARED_IMAGE_REF"
    wait_resolver "$CANARY_IP" 90
    validate_resolver "$CANARY_IP"
    echo OK') || fail "canary lifecycle failed: $out"
  grep -q '^OK$' <<<"$out" || fail "canary did not validate: $out"
  # Nothing must survive the run.
  docker ps -a --format '{{.Names}}' | grep -q 'unbound-canary' && fail "canary container leaked"
  docker volume ls --format '{{.Name}}'  | grep -q 'unbound-canary' && fail "canary volume leaked"
  docker network ls --format '{{.Name}}' | grep -q 'unbound-canary' && fail "canary network leaked"
  pass "canary starts on cloned state, validates, and leaves nothing behind"
}
```

- [ ] **Step 2: Lancer, vérifier les échecs**

```bash
bash tests/updater.sh
```
Attendu : `canary.sh: No such file or directory`.

- [ ] **Step 3: Écrire `updater/lib/canary.sh`**

```bash
#!/usr/bin/env bash
# Preflight configuration check and canary lifecycle.
#
# The canary runs the NEW image with the DECLARED configuration and a CLONE of
# production state, on an isolated bridge network. Production keeps serving
# throughout and is never touched.

# Names are derived at call time, not at source time: COMPOSE_PROJECT is set
# by discover_target, which necessarily runs after this file is sourced.
_canary_names() {
  [ -n "${COMPOSE_PROJECT:-}" ] || log_die "canary: COMPOSE_PROJECT is unset — discover_target must run first"
  CANARY_NAME="unbound-canary-$COMPOSE_PROJECT"
  CANARY_VOL="unbound-canary-vol-$COMPOSE_PROJECT"
  CANARY_NET="unbound-canary-net-$COMPOSE_PROJECT"
}

# preflight_checkconf <image_ref>
# Runs the new image's own unbound-checkconf against the declared config.
# This is what turns "the canary never became healthy" into an actionable
# error message naming the offending directive or file.
preflight_checkconf() {
  local ref="$1" out rc=0
  out=$(docker run --rm --entrypoint /usr/local/sbin/unbound-checkconf \
        "${DECLARED_BIND_MOUNTS[@]}" "$ref" /etc/unbound/unbound.conf 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_error "preflight: the declared configuration is not valid for $ref"
    printf '%s\n' "$out" >&2
    return 1
  fi
  log_info "preflight: configuration accepted by $ref"
  return 0
}

canary_down() {
  _canary_names
  docker network disconnect -f "$CANARY_NET" "$SELF_ID" >/dev/null 2>&1 || true
  docker rm -f "$CANARY_NAME"      >/dev/null 2>&1 || true
  docker volume rm "$CANARY_VOL"   >/dev/null 2>&1 || true
  docker network rm "$CANARY_NET"  >/dev/null 2>&1 || true
}

# canary_up <image_ref> — sets CANARY_IP.
canary_up() {
  local ref="$1"
  _canary_names
  canary_down   # clear leftovers from an interrupted run

  docker network create "$CANARY_NET" >/dev/null || { log_error "canary: cannot create network"; return 1; }
  docker volume create "$CANARY_VOL"  >/dev/null || { log_error "canary: cannot create volume"; return 1; }

  # Clone production state with our OWN image rather than pulling busybox:
  # every image in this chain is signed by the same pipeline.
  docker run --rm --entrypoint /bin/sh \
    -v "$TARGET_STATE_VOLUME":/src:ro -v "$CANARY_VOL":/dst \
    "$SELF_IMAGE" -c 'cp -a /src/. /dst/' \
    || { log_error "canary: cloning production state failed"; return 1; }

  docker run -d --name "$CANARY_NAME" --network "$CANARY_NET" \
    --cap-drop=ALL --cap-add=NET_BIND_SERVICE --security-opt no-new-privileges \
    -v "$CANARY_VOL":/var/lib/unbound "${DECLARED_BIND_MOUNTS[@]}" \
    "$ref" >/dev/null \
    || { log_error "canary: container failed to start"; return 1; }

  # Join the canary's network so we can query it directly. No published port,
  # so this works regardless of whether container IPs are routable from the host.
  docker network connect "$CANARY_NET" "$SELF_ID" >/dev/null \
    || { log_error "canary: cannot join the canary network"; return 1; }

  CANARY_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$CANARY_NET\").IPAddress}}" "$CANARY_NAME")
  [ -n "$CANARY_IP" ] || { log_error "canary: no IP address"; return 1; }
  log_info "canary running at $CANARY_IP on $ref"
  return 0
}

canary_logs() { _canary_names; docker logs "$CANARY_NAME" 2>&1 | tail -20 || true; }
```

- [ ] **Step 4: Reconstruire, relancer, vérifier T4, T5 et le cycle de vie**

```bash
docker build -t unbound-autoupdate:test updater/ && bash tests/updater.sh
```

- [ ] **Step 5: shellcheck puis commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
git add updater/lib/canary.sh tests/updater.sh
git commit -m "feat(updater): preflight checkconf and isolated canary"
```

---

### Task 5: Orchestrateur — tests T1, T2, T3

**Files:**
- Create: `updater/unbound-autoupdate`
- Modify: `tests/updater.sh`, `tests/updater/lib.sh`

**Interfaces:**
- Consumes: toutes les libs.
- Produces: exécutable `/usr/local/bin/unbound-autoupdate`, un cycle par invocation. Codes de sortie : `0` = à jour ou déployé et vérifié ; `1` = intervention humaine requise ; `2` = ignoré (quarantaine ou majeure refusée).
- Variables : `CHECK_ONLY` (`1` = jamais de swap), `WATCH_CONFIG` (défaut `1`), `ALLOW_MAJOR` (défaut `0`).

- [ ] **Step 1: Ajouter le helper de fixture pour l'image ancienne**

Dans `tests/updater/lib.sh` :

```bash
# OLD_REF is an immutable published revision; MOVING_REF is the tag users
# actually track. A cycle must move the container from one to the other.
OLD_REF="${OLD_REF:-esitcparis/unbound-distroless:1.26.0-r0}"
MOVING_REF="${MOVING_REF:-esitcparis/unbound-distroless:1}"

# updater_run <dir> [env=value…] — runs one cycle; echoes exit code on stdout.
updater_run() {
  local dir="$1"; shift
  local envs=()
  local kv; for kv in "$@"; do envs+=(-e "$kv"); done
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
    -f "$dir/docker-compose.yml" exec -T "${envs[@]}" updater \
    /usr/local/bin/unbound-autoupdate
}
```

- [ ] **Step 2: Écrire T1, T2, T3 (échouent)**

```bash
t1_image_update_actually_lands() {
  local dir="$TEST_TMPDIR/upd-t1-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$OLD_REF"
  local before; before=$(running_ref "$dir")

  # A new release appears: the declared tag now resolves to a newer digest.
  fixture_set_image "$dir" "$MOVING_REF"
  updater_run "$dir" || fail "cycle failed"

  local after declared
  after=$(running_ref "$dir")
  docker pull -q "$MOVING_REF" >/dev/null
  declared=$(docker image inspect "$MOVING_REF" --format '{{.Id}}')

  [ "$after" != "$before" ] || fail "T1: the container is still on the old image — the swap was a no-op"
  [ "$after" = "$declared" ] || fail "T1: running image ($after) is not the declared image ($declared)"
  pass "T1: after a cycle the container really runs the declared image"
}

t2_noop_second_cycle() {
  local dir="$TEST_TMPDIR/upd-t2-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "first cycle failed"
  local cid_before cid_after
  cid_before=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  updater_run "$dir" >/dev/null || fail "second cycle failed"
  cid_after=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  [ "$cid_before" = "$cid_after" ] || fail "T2: an unchanged cycle recreated the container"
  pass "T2: an unchanged cycle recreates nothing"
}

t3_config_change_triggers() {
  local dir="$TEST_TMPDIR/upd-t3-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local cid_before; cid_before=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)

  # A harmless, valid configuration edit.
  printf '\nserver:\n  cache-min-ttl: 120\n' >> "$dir/unbound.conf"
  updater_run "$dir" || fail "config-change cycle failed"

  local cid_after; cid_after=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  [ "$cid_before" != "$cid_after" ] || fail "T3: editing the configuration did not redeploy"
  pass "T3: a configuration change is canaried and deployed"
}
```

- [ ] **Step 3: Lancer, vérifier l'échec**

```bash
bash tests/updater.sh
```
Attendu : `unbound-autoupdate: not found` ou équivalent.

- [ ] **Step 4: Écrire `updater/unbound-autoupdate`**

```bash
#!/usr/bin/env bash
# One update cycle: discover → compare → verify → preflight → canary →
# validate → swap → post-swap gate → rollback on failure.
#
# Exit 0 = up to date, or updated and verified.
# Exit 1 = a human is needed (no Healthchecks success ping).
# Exit 2 = deliberately skipped (quarantine, or a refused major bump).
set -euo pipefail

LIB=/usr/local/lib/unbound-autoupdate
# shellcheck source=updater/lib/log.sh
. "$LIB/log.sh"
# shellcheck source=updater/lib/state.sh
. "$LIB/state.sh"
# shellcheck source=updater/lib/discover.sh
. "$LIB/discover.sh"
# shellcheck source=updater/lib/validate.sh
. "$LIB/validate.sh"
# shellcheck source=updater/lib/canary.sh
. "$LIB/canary.sh"

WATCH_CONFIG="${WATCH_CONFIG:-1}"
ALLOW_MAJOR="${ALLOW_MAJOR:-0}"
CHECK_ONLY="${CHECK_ONLY:-0}"
COSIGN_IDENTITY_REGEXP="${COSIGN_IDENTITY_REGEXP:-https://github.com/ESITC-Paris/unbound-distroless/.*}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"

state_init
exec 9>"$LOCK_FILE"
flock -n 9 || { log_info "another cycle is already running"; exit 0; }

hc_start
discover_target

RUNNING=$(running_digest)
compose pull --quiet "$TARGET_SERVICE" >/dev/null 2>&1 \
  || { log_error "docker compose pull failed"; hc_fail "pull failed"; exit 1; }
DECLARED=$(declared_digest)
CONF_HASH=$(config_fingerprint)
LAST_CONF=$(state_get LAST_CONFIG_HASH)

image_changed=0; conf_changed=0
[ "$DECLARED" != "$RUNNING" ] && image_changed=1
if [ "$WATCH_CONFIG" = 1 ] && [ -n "$LAST_CONF" ] && [ "$CONF_HASH" != "$LAST_CONF" ]; then
  conf_changed=1
fi

# First ever run: record the baseline instead of canarying a system that is
# already running fine. `check` mode is there for validating on demand.
if [ -z "$LAST_CONF" ]; then
  state_set LAST_CONFIG_HASH "$CONF_HASH"
  state_set LAST_IMAGE_DIGEST "$RUNNING"
  log_info "baseline recorded (image $RUNNING)"
  notify baseline "baseline recorded" "The updater is now watching $TARGET_SERVICE in project $COMPOSE_PROJECT."
fi

if [ "$image_changed" = 0 ] && [ "$conf_changed" = 0 ] && [ "$CHECK_ONLY" != 1 ]; then
  log_info "up to date ($RUNNING)"
  hc_success
  exit 0
fi

if [ "$image_changed" = 1 ] && quarantine_active "$DECLARED"; then
  log_warn "image $DECLARED is quarantined after a failed deployment — not retrying yet"
  notify skipped "update skipped (quarantine)" "Image $DECLARED previously failed its post-swap validation and was rolled back. It will not be retried before RETRY_AFTER=${RETRY_AFTER:-24h} elapses, or until a different image is published."
  hc_fail "quarantined image"
  exit 2
fi

if [ "$image_changed" = 1 ]; then
  old_v=$(image_version_label "$RUNNING"); new_v=$(image_version_label "$DECLARED")
  if [ -n "$old_v" ] && [ -n "$new_v" ] && [ "${old_v%%.*}" != "${new_v%%.*}" ] && [ "$ALLOW_MAJOR" != 1 ]; then
    log_warn "major version bump $old_v -> $new_v refused (set ALLOW_MAJOR=1 to accept)"
    notify skipped "major version bump not deployed" "The declared image moves Unbound from $old_v to $new_v. Major bumps are a deliberate human decision; set ALLOW_MAJOR=1 to allow them."
    hc_fail "major bump refused"
    exit 2
  fi
  [ -n "$old_v" ] && [ -n "$new_v" ] || log_warn "one of the images carries no version label — major-version guard skipped"

  if ! cosign verify "$DECLARED" \
        --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
        --certificate-oidc-issuer "$COSIGN_ISSUER" >/dev/null 2>&1; then
    log_error "cosign verification FAILED for $DECLARED — refusing to deploy"
    notify blocked "signature verification FAILED" "Image $DECLARED is not signed by the expected release pipeline. Deployment refused; production untouched. Investigate immediately."
    hc_fail "signature verification failed"
    exit 1
  fi
  log_info "cosign signature verified for $DECLARED"
fi

if ! preflight_checkconf "$DECLARED"; then
  notify blocked "configuration rejected in preflight" "The declared configuration is not valid for image $DECLARED. Production untouched. See the updater logs for unbound-checkconf's own message."
  hc_fail "preflight failed"
  exit 1
fi

trap canary_down EXIT
if ! canary_up "$DECLARED"; then
  notify blocked "canary could not start" "Image $DECLARED with the declared configuration failed to start in the canary. Production untouched."
  canary_logs >&2
  hc_fail "canary start failed"
  exit 1
fi
if ! wait_resolver "$CANARY_IP" 90 || ! validate_resolver "$CANARY_IP"; then
  log_error "canary validation FAILED — production untouched"
  canary_logs >&2
  notify blocked "canary rejected the update" "Image $DECLARED with the declared configuration and a clone of production state failed DNS validation. Production untouched; the cycle will retry."
  hc_fail "canary validation failed"
  exit 1
fi
log_info "canary validated: image, production state and configuration work together"
canary_down
trap - EXIT

if [ "$CHECK_ONLY" = 1 ]; then
  log_info "check mode: everything validated, no swap performed"
  hc_success
  exit 0
fi

# Compose keys recreation on the service's config hash, which the CONTENTS of
# a bind-mounted file do not affect. Without --force-recreate a config-only
# change would be a silent no-op that still reported success — the exact
# failure mode this project exists to remove.
recreate=()
[ "$image_changed" = 0 ] && recreate=(--force-recreate)

log_info "swapping $TARGET_SERVICE (brief restart)"
swap_ok=1
compose up -d --no-deps "${recreate[@]}" "$TARGET_SERVICE" >/dev/null 2>&1 || swap_ok=0

if [ "$swap_ok" = 1 ]; then
  TARGET_CONTAINER=$(compose ps -q "$TARGET_SERVICE")
  if [ -n "$TARGET_CONTAINER" ]; then
    probe=$(target_probe_ip)
    # 45s here, not the canary's 90s: the canary starts cold from a freshly
    # cloned volume, production restarts warm on an existing one. A resolver
    # silent for 45s after a swap is broken, and every extra second is broken
    # DNS. A spurious rollback is itself safe — it restores the working image.
    if wait_resolver "$probe" 45 && validate_resolver "$probe"; then
      state_set LAST_IMAGE_DIGEST "$DECLARED"
      state_set LAST_CONFIG_HASH "$CONF_HASH"
      quarantine_clear
      version=$(image_version_label "$DECLARED")
      log_info "production updated and verified: $DECLARED (unbound ${version:-unknown})"
      notify updated "updated successfully" "Project $COMPOSE_PROJECT, service $TARGET_SERVICE now runs $DECLARED (unbound ${version:-unknown}) and passed every post-deployment check."
      hc_success
      exit 0
    fi
  fi
fi

# ── Rollback ────────────────────────────────────────────────────────────────
log_error "post-swap validation failed — rolling back to $RUNNING"
COMPOSE_EXTRA_FILE="$STATE_DIR/rollback.yml"
printf 'services:\n  %s:\n    image: %s\n' "$TARGET_SERVICE" "$RUNNING" > "$COMPOSE_EXTRA_FILE"
rollback_ok=1
compose up -d --no-deps "$TARGET_SERVICE" >/dev/null 2>&1 || rollback_ok=0
TARGET_CONTAINER=$(compose ps -q "$TARGET_SERVICE" || true)
unset COMPOSE_EXTRA_FILE
quarantine_set "$DECLARED"

if [ "$rollback_ok" = 1 ] && [ -n "$TARGET_CONTAINER" ] \
   && probe=$(target_probe_ip) && wait_resolver "$probe" 45 && validate_resolver "$probe"; then
  log_info "rollback successful — production restored on $RUNNING"
  notify rollback "ROLLBACK performed" "The swap to $DECLARED failed its post-swap validation. Production was rolled back to $RUNNING and is healthy.

WARNING: the compose file still declares the failing image. Running 'docker compose up -d' by hand would redeploy it. The updater will not retry before RETRY_AFTER=${RETRY_AFTER:-24h}."
else
  log_error "rollback did NOT restore a healthy resolver — MANUAL INTERVENTION REQUIRED"
  notify critical "CRITICAL: rollback failed" "The swap to $DECLARED failed AND the rollback to $RUNNING did not restore a working resolver. DNS is likely down on this host. MANUAL INTERVENTION REQUIRED."
fi
hc_fail "post-swap validation failed"
exit 1
```

- [ ] **Step 5: Reconstruire, lancer T1–T3**

```bash
docker build -t unbound-autoupdate:test updater/ && bash tests/updater.sh
```
Attendu : `PASS: T1: …`, `PASS: T2: …`, `PASS: T3: …`.

- [ ] **Step 6: shellcheck puis commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning updater/unbound-autoupdate updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
git add updater/unbound-autoupdate tests/
git commit -m "feat(updater): cycle orchestrator with canary gate and rollback"
```

---

### Task 6: Garde-fous — tests T6 et T8

**Files:**
- Modify: `tests/updater.sh`, `updater/unbound-autoupdate` (uniquement si un test révèle un défaut)

**Interfaces:**
- Consumes: l'orchestrateur de la Task 5.
- Produces: aucun nouveau symbole. Cette tâche **vérifie** les garde-fous déjà écrits ; si un test échoue, c'est l'orchestrateur qui est corrigé.

- [ ] **Step 1: Ajouter le registre jetable aux helpers**

Les images fabriquées pour T6 et T8 doivent être **tirables**. Une image construite
localement n'a pas de `RepoDigests` et `compose pull` échoue : le cycle s'arrêterait
au pull et ni la barrière cosign ni le garde-fou de majeure ne seraient jamais
atteints — les deux tests passeraient pour la mauvaise raison. On les publie donc
dans un registre local jetable, que Docker traite comme non sécurisé d'office
sur `127.0.0.1`.

Dans `tests/updater/lib.sh` :

```bash
REGISTRY_NAME="upd-test-registry"
REGISTRY_HOST="127.0.0.1:5000"

# registry_up — a throwaway registry so crafted images are genuinely pullable.
# Without it `compose pull` fails first and the guard under test is never reached.
registry_up() {
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$REGISTRY_NAME" -p 127.0.0.1:5000:5000 \
    registry:2 >/dev/null
  local i
  for i in $(seq 1 30); do
    curl -fsS "http://$REGISTRY_HOST/v2/" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "local registry never became ready"
}

registry_down() { docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true; }

# registry_publish <dockerfile-text> <repo:tag> — builds and pushes, echoes the ref.
registry_publish() {
  local ref="$REGISTRY_HOST/$2"
  printf '%s\n' "$1" | docker build -q -t "$ref" - >/dev/null
  docker push -q "$ref" >/dev/null
  printf '%s\n' "$ref"
}

# fixture_set_image_raw <dir> <old-substring> <new-ref>
fixture_set_image_raw() {
  sed -i.bak "s|^    image: .*$2.*|    image: $3|" "$1/docker-compose.yml"
  rm -f "$1/docker-compose.yml.bak"
}
```

Le nom de dépôt contient `unbound`, ce que la découverte exige pour reconnaître
le service cible.

- [ ] **Step 2: Écrire T6 et T8**

```bash
t6_unsigned_image_refused() {
  local dir="$TEST_TMPDIR/upd-t6-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  # Same bits as a real release, but pushed to a registry we control and
  # therefore never signed by the release pipeline. It must not reach production.
  local fake
  fake=$(registry_publish "FROM $MOVING_REF" "unbound-unsigned:1")

  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image_raw "$dir" 'unbound-distroless' "$fake"
  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T6: an unsigned image was accepted"
  grep -qi 'cosign verification FAILED' <<<"$out" \
    || fail "T6: the run failed, but not at the signature gate — the test proves nothing: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "T6: production changed despite a failed signature check"
  pass "T6: unsigned image refused at the cosign gate, production untouched"
}

t8_major_bump_refused() {
  local dir="$TEST_TMPDIR/upd-t8-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  # Same bits, relabelled as a new major. The guard reads the OCI version
  # label rather than the tag, because a user tracking :latest has no major
  # version anywhere in their compose file.
  local fakemajor
  fakemajor=$(registry_publish \
    "FROM $MOVING_REF
LABEL org.opencontainers.image.version=\"2.0.0\"" "unbound-major:2")

  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image_raw "$dir" 'unbound-distroless' "$fakemajor"
  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T8: a major bump was deployed without ALLOW_MAJOR"
  grep -qi 'major version bump' <<<"$out" \
    || fail "T8: the run failed, but not at the major-version guard: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "T8: production moved to a new major version"

  # And the guard is a guard, not a wall: ALLOW_MAJOR=1 lets it through.
  rc=0
  updater_run "$dir" ALLOW_MAJOR=1 >/dev/null 2>&1 || rc=$?
  [ "$(running_ref "$dir")" != "$before" ] || fail "T8: ALLOW_MAJOR=1 did not permit the bump"
  pass "T8: major bump refused by default, allowed with ALLOW_MAJOR=1"
}
```

Chaque test exige que l'échec vienne **du garde-fou visé**, pas d'une erreur
quelconque en amont : c'est ce qui distingue un test qui verrouille un
comportement d'un test qui constate un code de retour non nul.

Note : l'image de T8 n'est pas signée non plus, mais le refus de majeure
précède la vérification cosign dans l'orchestrateur — c'est délibéré, il est
inutile de vérifier la signature de ce qu'on refuse de déployer. La seconde
moitié de T8 (`ALLOW_MAJOR=1`) échouera donc à la barrière cosign : l'assertion
porte sur le fait que la production **n'a pas bougé** pour la première moitié
et que le message a changé de garde-fou. Si l'implémenteur constate que
`ALLOW_MAJOR=1` ne peut pas aboutir à un déploiement, il remplace cette
assertion par : le journal ne contient plus `major version bump` et contient
`cosign verification FAILED`.

- [ ] **Step 3: Lancer les tests**

```bash
bash tests/updater.sh
```

- [ ] **Step 4: Si un test échoue, corriger l'orchestrateur, pas le test**

Un échec ici signifie qu'un garde-fou est réellement absent ou mal ordonné. Vérifier notamment que la vérification cosign précède tout `docker run` de l'image, et que le refus de majeure précède la vérification de signature — inutile de vérifier ce qu'on refuse de déployer.

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test(updater): cover the signature and major-version guards"
```

---

### Task 7: Rollback — tests T7a et T7b

**Files:**
- Modify: `tests/updater.sh`, `updater/unbound-autoupdate`

**Interfaces:**
- Consumes: l'orchestrateur.
- Produces: `_TEST_FORCE_POSTSWAP_FAIL` — déclencheur d'échec, lu uniquement par l'orchestrateur.

**Note sur l'honnêteté du test.** Le canari et la production sont conçus pour être aussi identiques que possible : les faire diverger authentiquement est donc difficile, ce qui est bon signe. Un seul axe diffère réellement — la publication de ports sur l'hôte. T7a l'exploite et est entièrement authentique. T7b force le déclencheur, mais **tout ce qui suit le déclencheur est réel** : véritable fichier d'override, véritable épinglage au digest, véritable re-validation. Ce qui est simulé, c'est l'événement ; ce qui est testé, c'est le mécanisme.

- [ ] **Step 1: Ajouter le déclencheur à l'orchestrateur**

Dans `updater/unbound-autoupdate`, remplacer la condition de succès post-swap :

```bash
    if [ "${_TEST_FORCE_POSTSWAP_FAIL:-0}" != 1 ] \
       && wait_resolver "$probe" 45 && validate_resolver "$probe"; then
```

et ajouter juste au-dessus du bloc `# ── Rollback ──` :

```bash
# _TEST_FORCE_POSTSWAP_FAIL exists so the integration suite can exercise the
# rollback machinery deterministically. It short-circuits ONLY the post-swap
# verdict: the override file, the digest pin, the re-validation and the
# quarantine below are the real code paths.
```

- [ ] **Step 2: Écrire T7a et T7b**

```bash
t7a_failed_swap_is_loud() {
  local dir="$TEST_TMPDIR/upd-t7a-$$" blocker="upd-t7a-blocker-$$" port=15353
  trap 'docker rm -f "$blocker" >/dev/null 2>&1 || true; fixture_destroy "$dir"' RETURN

  # The resolver publishes a host port. Publishing is the ONE axis on which a
  # canary and production genuinely differ, so it is the only way to stage an
  # authentic canary-green / production-red failure — which is exactly the
  # situation the post-swap gate exists for.
  fixture_create "$dir" "$OLD_REF" "$port"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"

  # Take the port. `compose up -d` will stop the old container and fail to
  # start the new one.
  docker run -d --name "$blocker" -p "127.0.0.1:$port:53/udp" --entrypoint /bin/sh \
    "$UPDATER_IMAGE" -c 'sleep 300' >/dev/null

  fixture_set_image "$dir" "$MOVING_REF"
  local rc=0 out
  out=$(updater_run "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "T7a: a failed swap reported success"
  grep -qi 'MANUAL INTERVENTION REQUIRED' <<<"$out" \
    || fail "T7a: a swap that left no working resolver did not raise the critical notification: $out"
  pass "T7a: a swap blocked by the environment fails loudly instead of silently"
}

t7b_rollback_restores_previous_digest() {
  local dir="$TEST_TMPDIR/upd-t7b-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$OLD_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image "$dir" "$MOVING_REF"
  local rc=0
  updater_run "$dir" _TEST_FORCE_POSTSWAP_FAIL=1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "T7b: a forced post-swap failure reported success"

  local after; after=$(running_ref "$dir")
  [ "$after" = "$before" ] || fail "T7b: rollback did not restore the previous image ($after != $before)"

  # And the resolver still works after the rollback.
  local out
  out=$(updater_exec "$dir" /bin/bash -c '
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/discover.sh
    . /usr/local/lib/unbound-autoupdate/validate.sh
    discover_target
    ip=$(target_probe_ip)
    wait_resolver "$ip" 90 && validate_resolver "$ip" && echo OK') || fail "resolver broken after rollback: $out"
  grep -q '^OK$' <<<"$out" || fail "T7b: resolver does not validate after rollback: $out"

  # The failing digest must now be quarantined: the next cycle must not retry.
  local cid_before cid_after
  cid_before=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  updater_run "$dir" >/dev/null 2>&1 || true
  cid_after=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" ps -q unbound)
  [ "$cid_before" = "$cid_after" ] || fail "T7b: the quarantined image was retried immediately"
  pass "T7b: rollback restores the previous digest, resolver validates, digest quarantined"
}
```

- [ ] **Step 3: Reconstruire et lancer**

```bash
docker build -t unbound-autoupdate:test updater/ && bash tests/updater.sh
```

- [ ] **Step 4: shellcheck puis commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning updater/unbound-autoupdate updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
git add updater/unbound-autoupdate tests/
git commit -m "test(updater): rollback, quarantine and loud-failure coverage"
```

---

### Task 8: Entrypoint, modes et boucle

**Files:**
- Create: `updater/entrypoint.sh`
- Modify: `tests/updater.sh`

**Interfaces:**
- Consumes: `to_seconds` (Task 1), `unbound-autoupdate` (Task 5).
- Produces: `entrypoint.sh` acceptant `loop` (défaut), `once`, `check`. Un argument prime sur `RUN_MODE`.

- [ ] **Step 1: Écrire le test des modes**

```bash
t_modes() {
  local dir="$TEST_TMPDIR/upd-modes-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$OLD_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"
  local before; before=$(running_ref "$dir")

  fixture_set_image "$dir" "$MOVING_REF"
  # check mode validates everything but must never swap.
  local out
  out=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
        -f "$dir/docker-compose.yml" exec -T updater \
        /usr/local/bin/entrypoint.sh check 2>&1) || fail "check mode failed: $out"
  grep -q 'check mode' <<<"$out" || fail "check mode did not announce itself: $out"
  [ "$(running_ref "$dir")" = "$before" ] || fail "check mode swapped production"
  pass "check mode validates the update without deploying it"

  out=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" \
        -f "$dir/docker-compose.yml" exec -T updater \
        /usr/local/bin/entrypoint.sh once 2>&1) || fail "once mode failed: $out"
  [ "$(running_ref "$dir")" != "$before" ] || fail "once mode did not deploy"
  pass "once mode runs exactly one cycle and deploys"
}
```

- [ ] **Step 2: Lancer, vérifier l'échec**

```bash
bash tests/updater.sh
```

- [ ] **Step 3: Écrire `updater/entrypoint.sh`**

```bash
#!/usr/bin/env bash
# Mode dispatch and scheduling loop.
#   loop  (default) — a cycle every INTERVAL, with SPLAY jitter
#   once            — exactly one cycle, then exit with its status
#   check           — one cycle that validates but never swaps
set -euo pipefail

LIB=/usr/local/lib/unbound-autoupdate
# shellcheck source=updater/lib/log.sh
. "$LIB/log.sh"
# shellcheck source=updater/lib/state.sh
. "$LIB/state.sh"

MODE="${1:-${RUN_MODE:-loop}}"
INTERVAL="${INTERVAL:-1h}"
SPLAY="${SPLAY:-10%}"

_delay() {
  local base pct max
  base=$(to_seconds "$INTERVAL")
  pct="${SPLAY%\%}"
  case "$pct" in ''|*[!0-9]*) log_die "invalid SPLAY: $SPLAY";; esac
  max=$(( base * pct / 100 ))
  # Jitter keeps a fleet of resolvers from all updating on the same minute.
  if [ "$max" -gt 0 ]; then
    printf '%s\n' $(( base + (RANDOM % (max + 1)) ))
  else
    printf '%s\n' "$base"
  fi
}

case "$MODE" in
  once)
    exec /usr/local/bin/unbound-autoupdate
    ;;
  check)
    CHECK_ONLY=1 exec /usr/local/bin/unbound-autoupdate
    ;;
  loop)
    log_info "unbound-autoupdate $(cat "$LIB/VERSION") starting: interval=$INTERVAL splay=$SPLAY"
    while true; do
      # A failing cycle must not kill the loop: it has already notified, and
      # the next tick retries. Only a human decision stops the sidecar.
      /usr/local/bin/unbound-autoupdate || log_warn "cycle exited non-zero; continuing"
      d=$(_delay)
      log_info "next cycle in ${d}s"
      sleep "$d" &
      wait $!   # `wait` on a background sleep so tini's SIGTERM lands promptly
    done
    ;;
  *)
    log_die "unknown mode '$MODE' (expected loop, once or check)"
    ;;
esac
```

- [ ] **Step 4: Reconstruire, relancer, vérifier**

```bash
docker build -t unbound-autoupdate:test updater/ && bash tests/updater.sh
```

- [ ] **Step 5: Vérifier l'arrêt propre**

```bash
docker run -d --name upd-sigterm -v /var/run/docker.sock:/var/run/docker.sock unbound-autoupdate:test loop
sleep 5
time docker stop upd-sigterm
docker rm -f upd-sigterm
```
Attendu : arrêt en moins de 3 s (pas les 10 s du timeout par défaut de Docker). Un arrêt lent signifie que `SIGTERM` n'atteint pas le `sleep`.

- [ ] **Step 6: shellcheck puis commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning updater/entrypoint.sh updater/unbound-autoupdate updater/lib/*.sh tests/updater.sh tests/updater/lib.sh
git add updater/entrypoint.sh tests/updater.sh
git commit -m "feat(updater): loop, once and check modes with prompt shutdown"
```

---

### Task 9: CI et publication

**Files:**
- Create: `.github/workflows/updater.yml`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `updater/`, `tests/updater.sh`.
- Produces: images `esitcparis/unbound-autoupdate` et `ghcr.io/esitc-paris/unbound-autoupdate`, tags `X.Y.Z`, `X.Y`, `X`, `latest`, publiées sur tag git `updater-vX.Y.Z`.

- [ ] **Step 1: Ajouter shellcheck et le test updater à `ci.yml`**

Dans le job `lint`, après l'étape actionlint :

```yaml
      - name: shellcheck (shell sources)
        run: |
          docker run --rm -v "$PWD:/mnt" -w /mnt \
            koalaman/shellcheck-alpine@sha256:PASTE_SHELLCHECK_DIGEST \
            shellcheck -S warning \
              tests/structure.sh tests/functional.sh tests/updater.sh tests/updater/lib.sh \
              updater/unbound-autoupdate updater/entrypoint.sh updater/lib/*.sh
```

Résoudre le digest :
```bash
docker buildx imagetools inspect koalaman/shellcheck-alpine:stable --format '{{println .Manifest.Digest}}' | head -1
```

Nouveau job, après `build-and-test` :

```yaml
  updater:
    runs-on: ubuntu-latest
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Build the updater image
        run: docker build -t unbound-autoupdate:test updater/

      - name: Install dig
        run: command -v dig >/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq bind9-dnsutils)

      # The suite drives real containers, real DNS and real cosign
      # verification against published images. It is the gate that would have
      # caught the tag-mismatch defect in the retired host-side updater.
      - name: Integration tests
        run: bash tests/updater.sh unbound-autoupdate:test

      - name: Trivy vulnerability scan (gate)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: unbound-autoupdate:test
          format: table
          exit-code: '1'
          severity: CRITICAL,HIGH
          ignore-unfixed: true
```

- [ ] **Step 2: Vérifier la CI localement**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
docker build -t unbound-autoupdate:test updater/ && bash tests/updater.sh
```

- [ ] **Step 3: Écrire `.github/workflows/updater.yml`**

Copier la structure de `release.yml` — mêmes garanties, périmètre différent :
- `on: push: tags: ['updater-v*']` plus `workflow_dispatch` avec une entrée `tag`.
- `prepare` : valider `^updater-v[0-9]+\.[0-9]+\.[0-9]+$`, extraire `full`/`minor`/`major`, croiser avec `updater/VERSION` et échouer en cas de désaccord — même invariant que le croisement tag ↔ `versions.env` de `release.yml`.
- `build` : matrice `linux/amd64` sur `ubuntu-latest` et `linux/arm64` sur `ubuntu-24.04-arm`, sans QEMU. Chaque arche construit, lance `bash tests/updater.sh`, passe Trivy, puis pousse par digest (`push-by-digest=true`, `sbom: true`, `provenance: mode=max`).
- `merge` : assembler les manifest lists sur les deux registres, signer avec `cosign-installer` épinglé sur `v2.6.5`, attester la provenance, créer la Release GitHub, ouvrir une issue de notification assignée à `euca01`.
- `notify-failure` : `if: failure()`, une issue par tag cassé, commentaires en cas de répétition.

Contraintes reprises telles quelles : actions épinglées au SHA, aucun `${{ }}` dans un corps `run:`, `concurrency: group: updater-release`.

Variables d'environnement du workflow :
```yaml
env:
  DOCKERHUB_IMAGE: esitcparis/unbound-autoupdate
  GHCR_IMAGE: ghcr.io/esitc-paris/unbound-autoupdate
```

- [ ] **Step 4: Valider le workflow**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
```
Attendu : aucune sortie.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/
git commit -m "ci(updater): shellcheck, integration gate and signed release pipeline"
```

---

### Task 10: Documentation et retrait de `deploy/`

**Files:**
- Create: `updater/README.md`, `updater/compose.snippet.yml`
- Modify: `README.md`, `docs/trust.md`, `docs/operations.md`, `docker-compose.yml`
- Delete: `deploy/install.sh`, `deploy/unbound-autoupdate`, `deploy/unbound-autoupdate.service`, `deploy/unbound-autoupdate.timer`
- Rewrite: `deploy/README.md` en stub

**Interfaces:** aucune.

- [ ] **Step 1: `updater/compose.snippet.yml`**

```yaml
# Drop this service into the same docker-compose.yml as your resolver.
# Replace /opt/unbound with YOUR project directory — the same absolute path
# must appear on both sides of the bind mount, because Compose resolves
# relative bind mounts against the project directory and the Docker daemon
# then applies them on the host.
  unbound-autoupdate:
    image: esitcparis/unbound-autoupdate:1
    restart: unless-stopped
    environment:
      INTERVAL: 1h
      # One Healthchecks.io check per host. The updater pings /start, success
      # and /fail, so every failure alerts immediately.
      HC_URL: https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/unbound:/opt/unbound:ro
      - autoupdate-state:/var/lib/unbound-autoupdate

volumes:
  autoupdate-state:
```

- [ ] **Step 2: `updater/README.md`**

Sections obligatoires, dans cet ordre :

1. **Ce que fait le sidecar** — le cycle en une liste courte, en insistant sur « la nouvelle image est validée avec *votre* configuration et un clone de *votre* état avant tout déploiement ».
2. **Le socket Docker vaut root sur l'hôte** — en tête, pas en note de bas de page. Expliquer qu'aucun updater de conteneurs ne peut s'en passer, et documenter l'option socket-proxy.
3. **Installation** — l'extrait compose, puis `docker compose up -d`.
4. **La contrainte de chemin identique** — pourquoi, et le message d'erreur exact qu'on obtient si on se trompe.
5. **Tester sans déployer** — `docker compose run --rm unbound-autoupdate check`.
6. **Table des variables** — reprendre §6 de la spec.
7. **Table des comportements** — une ligne par issue : rien de neuf, image non signée, canari rejeté, swap réussi, swap échoué, rollback échoué, majeure publiée, image en quarantaine.
8. **Ce que le sidecar ne fait pas** — Kubernetes, conteneurs hors Compose, auto-mise à jour (désactivée par défaut et pourquoi).

- [ ] **Step 3: Section dans le `README.md` racine**

Après « Images and tags », un paragraphe court renvoyant à `updater/README.md`, avec l'extrait compose minimal. Ne pas dupliquer la documentation : le README racine annonce, `updater/README.md` explique.

- [ ] **Step 4: Mettre à jour `docs/trust.md` et `docs/operations.md`**

`docs/trust.md` mentionne les mises à jour automatiques horaires : reformuler pour distinguer nettement les deux chaînes — publication (GitHub) et consommation (sidecar chez l'utilisateur). `docs/operations.md` : remplacer la section « Automatic server-side updates » par un renvoi à `updater/README.md`.

- [ ] **Step 5: Service commenté dans `docker-compose.yml`**

Ajouter le service `unbound-autoupdate` **en commentaire**, avec une ligne expliquant qu'il faut remplacer le chemin absolu. Le fichier racine est un exemple de production : il ne doit pas démarrer un conteneur privilégié sans décision explicite.

- [ ] **Step 6: Retirer `deploy/` et écrire le stub**

```bash
git rm deploy/install.sh deploy/unbound-autoupdate deploy/unbound-autoupdate.service deploy/unbound-autoupdate.timer
```

`deploy/README.md` devient le texte ci-dessous. Il contient lui-même un bloc de
code : l'écrire directement dans le fichier, ne pas transcrire un bloc imbriqué.

```
# Moved: see `updater/`

The host-side updater that used to live here has been removed. It was
**inoperative**: it pulled and validated the `:1` tag but performed the swap
with `docker compose up -d`, which deploys the tag written in the compose
file — `:latest` in this repository's own example. Pulling `:1` does not move
the local `:latest` pointer, and Compose does not re-pull by default, so the
swap was a no-op while the post-swap checks passed against the untouched old
container and the run reported success.

If you installed it, your resolver was very likely never actually updated:

```bash
systemctl disable --now unbound-autoupdate.timer
rm -f /usr/local/bin/unbound-autoupdate \
      /etc/systemd/system/unbound-autoupdate.{service,timer} \
      /etc/unbound-autoupdate.conf
systemctl daemon-reload
```

Its replacement is the **[`updater/`](../updater/README.md) sidecar**, which
swaps through Compose itself — making that class of disagreement structurally
impossible — and is covered by an integration suite that asserts the container
really ends up on the declared image.
```

- [ ] **Step 7: Vérifier la suite complète**

```bash
docker build -t unbound-autoupdate:test updater/
bash tests/updater.sh
bash tests/structure.sh esitcparis/unbound-distroless:1
grep -rn "deploy/unbound-autoupdate\|deploy/install.sh" --include='*.md' . || echo "no dangling references"
```

- [ ] **Step 8: Commit**

```bash
git add -A updater/ deploy/ README.md docs/ docker-compose.yml
git commit -m "docs(updater): user guide, compose snippet, and retire the host-side updater"
```

---

## Auto-relecture

**Couverture de la spec**

| Section de la spec | Tâche |
|---|---|
| §2 défaut de tag | T1 (Task 5) |
| §2 pas de prune global | Contrainte globale ; aucun `prune` dans le code écrit |
| §2 gate câblé sur 127.0.0.1 | `target_probe_ip` (Task 2) |
| §2 checkconf absent | T4 (Task 4) |
| §2 healthcheck cassé par la conf | T5 (Task 4), `wait_resolver` (Task 3) |
| §2 IP de bridge non routable | `docker network connect` (Task 4) |
| §2 busybox non vérifié | `canary_up` utilise `$SELF_IMAGE` (Task 4) |
| §2 pas de mode test | mode `check` (Task 8) |
| §5.1 découverte | Task 2 |
| §5.2 contrainte de chemin | `discover_target`, messages d'erreur dédiés (Task 2) |
| §5.3 cycle | Task 5 |
| §5.4 canari | Task 4 |
| §5.5 validation | Task 3 |
| §5.6 rollback et quarantaine | Task 7 |
| §6 interface et variables | Tasks 8 et 10 |
| §7 sécurité | Contraintes globales, README (Task 10) |
| §8 image | Task 1 |
| §9 tests T1–T8 | Tasks 4 à 7 |
| §10 impact dépôt | Tasks 9 et 10 |
| §11 prérequis | Ci-dessous |

**Cohérence des noms** — `DECLARED_BIND_MOUNTS`, `TARGET_STATE_VOLUME`, `COMPOSE_FILE_ARGS`, `CANARY_IP`, `SELF_ID`, `SELF_IMAGE` sont définis en Task 2/4 et utilisés sous ces noms exacts ensuite. `to_seconds` est défini en Task 1 (`state.sh`) et consommé en Task 8 (`entrypoint.sh`), qui source bien `state.sh`.

**Écart assumé** — trois digests d'images (`alpine`, `cosign`, `shellcheck-alpine`) sont résolus par une commande explicite au moment de l'implémentation plutôt qu'inscrits ici : une valeur inventée serait pire qu'une commande à exécuter.

## Prérequis de lancement (hors dépôt)

1. Créer le dépôt Docker Hub `esitcparis/unbound-autoupdate`.
2. Vérifier que `DOCKERHUB_TOKEN` peut y écrire.
3. Après le premier `updater-v1.0.0`, rendre le paquet GHCR public (interface web).
