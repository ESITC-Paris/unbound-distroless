# Sidecar production grade — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rendre le sidecar `unbound-autoupdate` déployable (modes, boucle), supervisable (métriques Prometheus, alertes), auto-entretenu (self-update par conteneur éphémère, vérification par clé) et publié par une chaîne signée dont les bases sont surveillées par le moniteur.

**Architecture:** Une image Alpine 3.24, deux services compose (`loop` et `metrics`), un processus par conteneur. Le cycle existant est conservé ; on lui ajoute une fonction de sortie unique qui écrit les métriques, une bibliothèque de vérification cosign à deux modes, une bibliothèque de self-update dont l'application s'exécute dans un conteneur éphémère lancé depuis la nouvelle image, et un CGI `httpd` qui convertit `unbound-control stats_noreset` au format Prometheus. Côté CI : shellcheck, job d'intégration, workflow `updater.yml` calqué sur `release.yml`, moniteur étendu aux digests Alpine et cosign.

**Tech Stack:** bash, docker CLI + plugin compose, cosign v2.6.5, bind-tools, busybox-extras (`httpd`, `nc`), jq, awk, Alpine 3.24, GitHub Actions, promtool (`prom/prometheus`).

**Spec:** `docs/superpowers/specs/2026-09-16-sidecar-production-grade-design.md` (lire aussi `docs/superpowers/specs/2026-09-06-sidecar-autoupdate-design.md` pour le cycle).

## Global Constraints

- Shell : `bash`, `set -euo pipefail` en tête de chaque exécutable ; bibliothèques sourcées sans options. Tout passe `shellcheck -S warning`.
- Prose et commentaires du code : **anglais**. Ce plan et la spec sont en français.
- **Toute conclusion vient du code et des tests exécutés, jamais d'un document.** Chaque test est vu ROUGE avant le correctif, puis VERT.
- Aucun `docker image prune` / `docker system prune`. `docker compose up` porte **toujours** `--no-deps`.
- Toute image tierce est épinglée par digest. Actions GitHub épinglées au SHA complet avec le tag en commentaire. Aucun `${{ }}` dans un corps `run:` : uniquement via `env:`.
- Chemins : `STATE_DIR=/var/lib/unbound-autoupdate`, libs dans `/usr/local/lib/unbound-autoupdate/`, docroot `/usr/local/lib/unbound-autoupdate/www/`.
- Le sidecar est **Alpine 3.24** (décision du mainteneur). Digest résolu le 2026-09-16 : `alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b`. cosign : `ghcr.io/sigstore/cosign/cosign:v2.6.5@sha256:ad281047f85c5e1fc6ffbc30c2b55be3b07b4032bef715a12122ce5829619aca`. promtool : `prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996`.
- Commits : conventional commits, **aucune mention d'un assistant ni trailer d'attribution**. Jamais de `git push`.
- Pour lancer un sous-ensemble de la suite : `ONLY="t_a t_b" bash tests/updater.sh`. Reconstruire l'image avant chaque run : `docker build -t unbound-autoupdate:test updater/`.
- La suite a besoin d'Internet (Docker Hub, Sigstore) et des ports hôte 5000 et 15353 libres. Durée complète : environ 15 min.
- Faits vérifiés sur `alpine:3.24` le 2026-09-16 : `httpd` est dans le paquet `busybox-extras` (pas dans busybox de base) ; sa règle `P:/metrics:http://127.0.0.1:<port>/cgi-bin/metrics` fonctionne ; `nc -l -p PORT -e PROG` fonctionne ; jq 1.8 **supprime les octets NUL** de sa sortie brute (jamais de NUL-délimitation via jq, utiliser `@base64` par ligne) ; `promtool check metrics` retourne 3 si une métrique n'a pas de ligne `# HELP`.

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `updater/lib/discover.sh` | + `discover_target_container` (labels seuls), exclusion des frères sur la même image |
| `updater/lib/verify.sh` | `verify_image <ref>` : keyless ou `--key` |
| `updater/lib/state.sh` | quarantaines génériques (`image`, `config`, `self`), `state_inc` |
| `updater/lib/metrics.sh` | `stats_to_prometheus` (stdin → texte Prometheus), `write_cycle_metrics` |
| `updater/lib/selfupdate.sh` | `self_update` (détection, gardes, lancement du helper), `self_update_apply` (helper) |
| `updater/unbound-autoupdate` | cycle ; `finish <status> <code>` ; hook self-update |
| `updater/entrypoint.sh` | modes `loop`, `once`, `check`, `metrics`, `self-update-apply` |
| `updater/www/cgi-bin/metrics` | CGI de scrape |
| `updater/Dockerfile` | Alpine 3.24, `busybox-extras`, build-args digests, VERSION généré |
| `tests/updater/lib.sh` | fixtures à trois services, registre relayé, clés cosign de test, promtool |
| `tests/updater.sh` | tests §8 de la spec |
| `.github/workflows/{ci,release,upstream-check,updater}.yml` | CI, verify post-signature, moniteur étendu, publication du sidecar |
| `versions.env`, `.build-state.json` | `UPDATER_VERSION`, `UPDATER_REVISION`, digests `alpine`, `cosign` |
| `updater/README.md`, `updater/compose.snippet.yml`, `docs/observability/*`, `docs/trust.md`, `README.md`, `docker-compose.yml` | documentation |

---

### Task 1: Découverte — frères sur la même image, troisième service de fixture

**Files:**
- Modify: `updater/lib/discover.sh` (fonction `discover_target`)
- Modify: `tests/updater/lib.sh` (`fixture_create`)
- Test: `tests/updater.sh` (`t_discover`)

**Interfaces:**
- Consumes: `log_die`, `_label` (existants).
- Produces: `discover_target_container` — positionne `SELF_ID`, `SELF_IMAGE`, `SELF_IMAGE_ID`, `COMPOSE_PROJECT`, `TARGET_CONTAINER`, `TARGET_SERVICE` sans lire le projet compose. `discover_target` l'appelle puis lit le reste comme aujourd'hui. `_image_repo <ref>` — la partie dépôt d'une référence, sans tag ni digest.

- [ ] **Step 1: Ajouter le service `metrics` à toutes les fixtures**

Dans `tests/updater/lib.sh`, `fixture_create`, entre le bloc `updater:` (après sa ligne `${FIXTURE_UPDATER_EXTRA:-}`) et `volumes:`, insérer :

```yaml
  metrics:
    image: ${FIXTURE_UPDATER_IMAGE:-$UPDATER_IMAGE}
    command: ["metrics"]
    ports:
      - "127.0.0.1::9167"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ustate:/var/lib/unbound-autoupdate:ro
```

et remplacer, dans le bloc `updater:`, `image: $UPDATER_IMAGE` par `image: ${FIXTURE_UPDATER_IMAGE:-$UPDATER_IMAGE}` et `entrypoint: ["sleep", "infinity"]` par `command: ["idle"]` (l'entrypoint de l'image reste tini + `entrypoint.sh` ; `idle` est un mode qui garde le conteneur en vie sans lancer de cycle, ajouté en Task 4a — jusque-là le placeholder ignore l'argument et dort). Ajouter le commentaire au-dessus de `fixture_create` :

```bash
# FIXTURE_UPDATER_IMAGE: image reference for BOTH sidecar services (updater and
# metrics); defaults to the locally built test image. The self-update tests
# point it at the throwaway registry so that `compose pull` has somewhere to
# pull from and the running sidecar carries a repository digest.
```

Le placeholder d'`entrypoint.sh` ignore ses arguments et fait `sleep infinity`, donc `updater` et `metrics` démarrent et restent en vie dès maintenant ; les Tasks 4a et 4b leur donnent leurs vrais rôles.

- [ ] **Step 2: Lancer `t_discover`, vérifier l'échec**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY=t_discover bash tests/updater.sh
```

Attendu : `FAIL: discover_target failed: ... discovery found 2 candidate services ( updater metrics)` — l'image du sidecar contient « unbound », donc le conteneur `metrics` est pris pour un résolveur. Si le test passe, la fixture n'a pas démarré `metrics` : vérifier `docker ps`.

- [ ] **Step 3: Scinder la découverte et exclure les frères sur la même image**

Dans `updater/lib/discover.sh`, remplacer la fonction `discover_target` entière par :

```bash
# _image_repo <ref> — the repository part of an image reference: no tag, no
# digest. "127.0.0.1:5000/unbound-x:1" and "127.0.0.1:5000/unbound-x@sha256:…"
# both give "127.0.0.1:5000/unbound-x". The registry port is not a tag: only
# the LAST path component is inspected for a colon.
_image_repo() {
  local ref="${1%%@*}" last
  last="${ref##*/}"
  case "$last" in *:*) ref="${ref%:*}" ;; esac
  printf '%s\n' "$ref"
}

# discover_target_container — SELF_* and the target container, from labels
# only. Enough for the metrics CGI, which must not need the compose project
# files; discover_target builds on it.
discover_target_container() {
  SELF_ID=$(discover_self_id) || log_die "cannot determine my own container id — is /var/run/docker.sock mounted?"
  SELF_IMAGE=$(docker inspect "$SELF_ID" --format '{{.Config.Image}}')
  SELF_IMAGE_ID=$(docker inspect "$SELF_ID" --format '{{.Image}}')

  COMPOSE_PROJECT=$(_label "$SELF_ID" com.docker.compose.project)
  [ -n "$COMPOSE_PROJECT" ] || log_die "this container is not managed by docker compose"

  # Candidate = sibling service in the same project whose image repository
  # mentions unbound. Deliberately loose so forks and private mirrors work.
  # A sibling running the sidecar's OWN image (the metrics service, a second
  # updater) is never the resolver, whatever its repository name contains —
  # and "unbound-autoupdate" does contain "unbound".
  local candidates=() cid img self_repo
  self_repo=$(_image_repo "$SELF_IMAGE")
  while read -r cid; do
    [ "$cid" = "$SELF_ID" ] && continue
    img=$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null) || continue
    [ "$(_image_repo "$img")" = "$self_repo" ] && continue
    case "$img" in
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
}

discover_target() {
  discover_target_container

  COMPOSE_WORKDIR=$(_label "$TARGET_CONTAINER" com.docker.compose.project.working_dir)
  local files; files=$(_label "$TARGET_CONTAINER" com.docker.compose.project.config_files)
  [ -n "$files" ] && [ -n "$COMPOSE_WORKDIR" ] || log_die "target container carries no compose file labels"

  _compose_file_args "$files"

  _read_declared
  _read_running_mounts
}
```

Le commentaire `# shellcheck disable=SC2034` qui précédait `SELF_IMAGE=` doit rester au-dessus de cette ligne (la variable est consommée ailleurs).

- [ ] **Step 4: Étendre `t_discover`**

Dans `tests/updater.sh`, dans le script de `t_discover`, ajouter avant `echo "notifyhost=..."` :

```bash
    echo "selfimageid=$SELF_IMAGE_ID"
    echo "repo=$(_image_repo "127.0.0.1:5000/unbound-x:1") $(_image_repo "127.0.0.1:5000/unbound-x@sha256:abc") $(_image_repo "esitcparis/unbound-distroless:1.26.0-r3")"
```

et après le bloc `notifyhost` :

```bash
  grep -qE '^selfimageid=sha256:[0-9a-f]{64}$' <<<"$out" || fail "SELF_IMAGE_ID not derived: $out"
  grep -q '^repo=127.0.0.1:5000/unbound-x 127.0.0.1:5000/unbound-x esitcparis/unbound-distroless$' <<<"$out" \
    || fail "_image_repo mishandles a registry port, a digest or a tag: $out"
```

Mettre à jour le libellé `pass` : `"discovery derives service, workdir, declared ref, volume, bind mounts, compose file args; a sibling on the sidecar's own image is never a candidate"`.

- [ ] **Step 5: Reconstruire, relancer**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t_discover t_canary_lifecycle t2_noop_second_cycle" bash tests/updater.sh
```

Attendu : trois PASS.

- [ ] **Step 6: shellcheck, commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning updater/lib/discover.sh tests/updater.sh tests/updater/lib.sh
git add updater/lib/discover.sh tests/updater.sh tests/updater/lib.sh
git commit -m "feat(updater): label-only discovery, never mistake a sibling on the sidecar's image for the resolver"
```

---

### Task 2: Vérification par clé, registre jetable joignable, test positif de signature

**Files:**
- Create: `updater/lib/verify.sh`
- Modify: `updater/unbound-autoupdate` (sourcing, appel cosign)
- Modify: `tests/updater/lib.sh` (`registry_up`, `registry_forward`, `cosign_test_keys`, `registry_sign`)
- Test: `tests/updater.sh` (`t_verify_key_accepts_signed`, `t6_unsigned_image_refused`)

**Interfaces:**
- Consumes: `log_error` (existant).
- Produces: `verify_image <ref>` — 0 si la signature est valide ; sinon 1 et la sortie de cosign sur stderr. Variables : `COSIGN_PUBLIC_KEY` (chemin PEM ; vide = keyless), `COSIGN_IGNORE_TLOG` (`1` ajoute `--insecure-ignore-tlog`, mode clé seulement), `COSIGN_IDENTITY_REGEXP`, `COSIGN_ISSUER`.
- Produces (tests) : `registry_forward <dir>` — rend `127.0.0.1:5000` joignable **depuis l'intérieur** du sidecar de la fixture ; `cosign_test_keys <dir>` — génère `testkey.key`/`testkey.pub` dans le volume d'état du sidecar ; `registry_sign <dir> <ref>` — signe `<ref>` avec cette clé.

Pourquoi le relais : le démon Docker tire `127.0.0.1:5000/...` via le port publié sur la boucle locale de l'hôte, mais `cosign verify` s'exécute **dans** le sidecar, où `127.0.0.1:5000` est la boucle locale du conteneur. Sans relais, T6 échouait sur « connexion refusée » et non sur « aucune signature » : il prouvait le bon résultat pour la mauvaise raison. Le relais est un `nc -l -p 5000 -e nc registry 5000` en boucle dans le sidecar, le registre étant raccordé au réseau de la fixture sous l'alias `registry`. cosign parle HTTP sans option pour `127.0.0.1` (go-containerregistry traite les adresses de boucle locale comme non sécurisées).

- [ ] **Step 1: Helpers de test**

Dans `tests/updater/lib.sh`, après `registry_publish`, ajouter :

```bash
# registry_forward <dir> — make 127.0.0.1:5000 INSIDE the fixture's sidecar
# reach the throwaway registry. The daemon pulls through the host's published
# port, but cosign runs inside the sidecar where 127.0.0.1 is the container's
# own loopback. The registry is connected to the fixture network under the
# alias "registry" and a busybox nc relay loops in the sidecar for the life
# of the fixture. Without this, an unsigned-image test fails on "connection
# refused" instead of "no signatures found" — the right verdict for the
# wrong reason.
registry_forward() {
  local dir="$1" net
  net="$(fixture_project "$dir")_default"
  docker network connect --alias registry "$net" "$REGISTRY_NAME" >/dev/null 2>&1 || true
  updater_exec "$dir" /bin/sh -c \
    'nohup sh -c "while true; do nc -l -p 5000 -e nc registry 5000; done" >/dev/null 2>&1 &'
  # Prove the relay before any test relies on it.
  local _i
  for _i in $(seq 1 10); do
    updater_exec "$dir" /bin/sh -c 'wget -qO- http://127.0.0.1:5000/v2/ >/dev/null 2>&1' && return 0
    sleep 1
  done
  fail "registry relay inside the sidecar never came up"
}

# cosign_test_keys <dir> — a throwaway key pair in the sidecar's state volume,
# so the same path is valid inside the updater container, the metrics
# container and the self-update helper. Empty password; never leaves /tmp.
cosign_test_keys() {
  updater_exec "$1" /bin/sh -c \
    'cd /var/lib/unbound-autoupdate && rm -f testkey.key testkey.pub && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix testkey >/dev/null 2>&1'
}
TEST_PUBKEY=/var/lib/unbound-autoupdate/testkey.pub

# registry_sign <dir> <ref> — sign <ref> in the throwaway registry with the
# test key, from inside the sidecar (which is where the relay lives). No
# transparency-log upload: this is a private, ephemeral registry.
registry_sign() {
  updater_exec "$1" /bin/sh -c \
    "COSIGN_PASSWORD='' cosign sign --key /var/lib/unbound-autoupdate/testkey.key --tlog-upload=false --yes '$2' >/dev/null 2>&1" \
    || fail "could not sign $2 with the test key"
}
```

Dans `registry_down`, avant le `docker rm -f`, rien à ajouter : supprimer le conteneur le détache de tous les réseaux.

Le relais `nc` sert une connexion à la fois ; cosign enchaîne ses requêtes, ce qui suffit. Si un test échoue par intermittence sur « connection refused » vers `127.0.0.1:5000` **depuis le sidecar**, remplacer le relais par `socat` installé à la volée dans le conteneur de test (`apk add --no-cache socat` puis `socat TCP-LISTEN:5000,fork,reuseaddr TCP:registry:5000 &`) — jamais en ajoutant socat à l'image.

- [ ] **Step 2: Écrire le test qui échoue**

Dans `tests/updater.sh`, avant `t6_unsigned_image_refused` :

```bash
t_verify_key_accepts_signed() {
  # Key-based verification, for private mirrors that re-sign: an image
  # signed with the configured public key passes, the same bits unsigned do
  # not, and the refusal carries cosign's own reason — not a connection
  # error, which is what an unreachable registry would produce.
  local dir="$TEST_TMPDIR/upd-keyed-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local signed unsigned
  signed=$(registry_publish "FROM $MOVING_REF
LABEL test.keyed=\"1\"" "unbound-keyed:1")
  unsigned=$(registry_publish "FROM $MOVING_REF
LABEL test.keyed=\"0\"" "unbound-unkeyed:1")
  registry_sign "$dir" "$signed"

  local out
  out=$(updater_exec "$dir" /bin/bash -c "
    set -uo pipefail
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/verify.sh
    export COSIGN_PUBLIC_KEY=$TEST_PUBKEY COSIGN_IGNORE_TLOG=1
    verify_image '$signed' 2>/tmp/err || { echo 'signed image refused:'; cat /tmp/err; exit 1; }
    if verify_image '$unsigned' 2>/tmp/err; then echo 'unsigned image accepted'; exit 1; fi
    grep -qiE 'no signatures found|no matching signatures' /tmp/err || { echo 'refusal is not about signatures:'; cat /tmp/err; exit 1; }
    # An unreadable key file must be a clear refusal, never a fall-through to keyless.
    if COSIGN_PUBLIC_KEY=/does/not/exist verify_image '$signed' 2>/tmp/err; then echo 'missing key file was ignored'; exit 1; fi
    grep -q 'not readable' /tmp/err || { echo 'missing key not reported:'; cat /tmp/err; exit 1; }
    echo OK") || fail "key verification: $out"
  grep -q '^OK$' <<<"$out" || fail "key verification did not reach OK: $out"
  pass "verify_image: key mode accepts a key-signed image, refuses an unsigned one with cosign's reason, refuses a missing key"
}
```

Ajouter `t_verify_key_accepts_signed` dans `ALL_TESTS` juste avant `t6_unsigned_image_refused`.

- [ ] **Step 3: Lancer, vérifier l'échec**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY=t_verify_key_accepts_signed bash tests/updater.sh
```

Attendu : `FAIL: key verification: ... verify.sh: No such file or directory`.

- [ ] **Step 4: Écrire `updater/lib/verify.sh`**

```bash
#!/usr/bin/env bash
# Image signature verification, fail-closed, in one of two exclusive modes:
#   keyless (default): the signing identity must be this repository's release
#                      workflow, proven by the GitHub OIDC certificate;
#   key:               COSIGN_PUBLIC_KEY names a PEM public key, for a private
#                      mirror that re-signs what it serves.
# cosign's own output is written to stderr whenever verification fails: an
# operator must see WHY a signature was refused, not only that it was.

COSIGN_IDENTITY_REGEXP="${COSIGN_IDENTITY_REGEXP:-https://github.com/ESITC-Paris/unbound-distroless/.*}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"

# verify_image <ref> — 0 when the signature checks out.
verify_image() {
  local ref="$1" out rc=0
  local args=()
  if [ -n "${COSIGN_PUBLIC_KEY:-}" ]; then
    if [ ! -r "$COSIGN_PUBLIC_KEY" ]; then
      log_error "COSIGN_PUBLIC_KEY '$COSIGN_PUBLIC_KEY' is not readable — refusing to verify without it"
      return 1
    fi
    args=(--key "$COSIGN_PUBLIC_KEY")
    # A private mirror's signatures are typically not in the public Rekor log.
    [ "${COSIGN_IGNORE_TLOG:-0}" = 1 ] && args+=(--insecure-ignore-tlog)
  else
    args=(--certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" --certificate-oidc-issuer "$COSIGN_ISSUER")
  fi
  out=$(cosign verify "${args[@]}" "$ref" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 5: Brancher l'orchestrateur**

Dans `updater/unbound-autoupdate` : ajouter après le sourcing de `canary.sh` :

```bash
# shellcheck source=updater/lib/verify.sh
. "$LIB/verify.sh"
```

Supprimer les deux lignes `COSIGN_IDENTITY_REGEXP=` et `COSIGN_ISSUER=` (elles vivent dans `verify.sh`). Remplacer le bloc :

```bash
  if ! cosign verify "$DECLARED" \
        --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
        --certificate-oidc-issuer "$COSIGN_ISSUER" >/dev/null 2>&1; then
```

par :

```bash
  if ! verify_image "$DECLARED"; then
```

Le message `cosign verification FAILED for … — refusing to deploy` reste identique (T6 et T8 le cherchent).

- [ ] **Step 6: Rendre T6 honnête**

Dans `t6_unsigned_image_refused`, après `fixture_create "$dir" "$MOVING_REF"`, ajouter `registry_forward "$dir"`. Après le `grep -qi 'cosign verification FAILED'`, ajouter :

```bash
  # With the registry reachable from inside the sidecar, the refusal must be
  # cosign's verdict on the image, not a network error dressed up as one.
  grep -qiE 'no signatures found|no matching signatures' <<<"$out" \
    || fail "T6: cosign did not report a missing signature — was the registry reachable from the sidecar? $out"
```

Faire de même dans `t8_major_bump_refused` (ajouter `registry_forward "$dir"` après `fixture_create`), sans nouvelle assertion.

- [ ] **Step 7: Reconstruire, relancer**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t_verify_key_accepts_signed t6_unsigned_image_refused t8_major_bump_refused" bash tests/updater.sh
```

Attendu : trois PASS. Si T6 échoue sur la nouvelle assertion, lire le message réel de cosign dans la sortie et **ne pas** élargir le motif à une erreur réseau : corriger le relais.

- [ ] **Step 8: shellcheck, commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning updater/lib/verify.sh updater/unbound-autoupdate tests/updater.sh tests/updater/lib.sh
git add updater/lib/verify.sh updater/unbound-autoupdate tests/updater.sh tests/updater/lib.sh
git commit -m "feat(updater): key-based cosign verification, registry reachable from inside the test sidecar"
```

---

### Task 3: Quarantaines génériques, métriques du cycle, conversion des statistiques

**Files:**
- Modify: `updater/lib/state.sh`
- Create: `updater/lib/metrics.sh`
- Modify: `updater/unbound-autoupdate` (fonction `finish`, trap unique, statuts)
- Test: `tests/updater.sh` (`t0_stats_to_prometheus_unit`, `t0_cycle_metrics_unit`), `tests/updater/lib.sh` (`promtool_check`)

**Interfaces:**
- Consumes: `state_get`, `state_set`, `to_seconds`, `log_*`.
- Produces (`state.sh`) : `state_inc <key>` ; `self_quarantine_set <digest>` / `self_quarantine_clear` / `self_quarantine_active <digest>` (mêmes sémantiques que `quarantine_*`, clés `SELF_QUARANTINE_DIGEST`/`SELF_QUARANTINE_TS`) ; `_quarantine_window_open <tskey>` — 0 si la clé horodatage est posée et `RETRY_AFTER` non écoulé.
- Produces (`metrics.sh`) : `stats_to_prometheus` — stdin `clé=valeur`, stdout texte Prometheus ; `record_cycle <status> <duration_seconds>` — persiste `LAST_CYCLE_STATUS`, `LAST_CYCLE_TS`, `LAST_CYCLE_DURATION`, incrémente `CYCLES_<STATUS>` et réécrit `$STATE_DIR/metrics.prom` ; `write_cycle_metrics` — réécrit `metrics.prom` depuis l'état (utilisé aussi par le helper de self-update, Task 5). Statuts autorisés : `up_to_date updated check_ok skipped blocked rollback critical error`.
- Produces (orchestrateur) : `finish <status> <code>` — `record_cycle` puis `exit <code>`. Tout `exit` du cycle passe par `finish` ; une mort inattendue (`log_die`, `set -e`) est enregistrée `error` par le trap EXIT.
- Produces (tests) : `promtool_check <file>` — 0 si `promtool check metrics` accepte le fichier.

- [ ] **Step 1: Helper promtool**

Dans `tests/updater/lib.sh`, après `registry_sign` :

```bash
# promtool_check <file> — the Prometheus text exposition format has a
# reference parser; use it rather than hand-rolled greps. Exit 3 means lint
# problems (a metric without HELP, a bad name), which count as failures.
PROMTOOL_IMAGE="prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996"
promtool_check() {
  docker run --rm -i --entrypoint promtool "$PROMTOOL_IMAGE" check metrics < "$1"
}
```

- [ ] **Step 2: Écrire les deux tests unitaires qui échouent**

Dans `tests/updater.sh`, après `t0_config_fingerprint_directory_unit` :

```bash
t0_stats_to_prometheus_unit() {
  # A canned stats_noreset excerpt (the shapes unbound 1.26 actually prints)
  # must come out as valid exposition text: grouped families, HELP and TYPE
  # on every one, labels where the key encodes a dimension, and a real
  # cumulative histogram built from unbound's non-cumulative buckets.
  local out="$TEST_TMPDIR/upd-stats-$$.prom"
  docker run --rm -i --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    stats_to_prometheus' > "$out" <<'STATS'
thread0.num.queries=7
thread0.num.cachehits=3
thread0.requestlist.avg=0.5
thread1.num.queries=5
thread1.num.cachehits=2
thread1.requestlist.avg=0
total.num.queries=12
total.num.cachehits=5
total.num.recursivereplies=4
total.requestlist.avg=0.25
total.recursion.time.avg=0.125000
total.recursion.time.median=0.05
total.tcpusage=0
time.now=1789568511.123456
time.up=100.500000
time.elapsed=100.500000
mem.cache.rrset=4096
mem.cache.message=2048
mem.mod.validator=512
histogram.000000.000000.to.000000.000001=0
histogram.000000.000001.to.000000.000002=1
histogram.000000.000002.to.000000.000004=2
histogram.000000.000004.to.000000.000008=1
num.query.type.A=10
num.query.type.AAAA=2
num.query.class.IN=12
num.query.opcode.QUERY=12
num.query.tcp=1
num.query.flags.RD=12
num.query.edns.present=12
num.answer.rcode.NOERROR=11
num.answer.rcode.NXDOMAIN=1
num.query.aggressive.NXDOMAIN=1
num.answer.secure=9
num.answer.bogus=0
num.rrset.bogus=0
unwanted.queries=0
unwanted.replies=0
msg.cache.count=8
rrset.cache.count=20
infra.cache.count=3
key.cache.count=2
STATS
  promtool_check "$out" || fail "stats_to_prometheus output rejected by promtool: $(cat "$out")"
  local expect
  for expect in \
    '^unbound_total_num_queries 12$' \
    '^unbound_thread_num_queries{thread="1"} 5$' \
    '^unbound_thread_requestlist_avg{thread="0"} 0.5$' \
    '^unbound_query_types_total{type="AAAA"} 2$' \
    '^unbound_answer_rcodes_total{rcode="NXDOMAIN"} 1$' \
    '^unbound_query_aggressive_total{rcode="NXDOMAIN"} 1$' \
    '^unbound_answers_secure_total 9$' \
    '^unbound_recursion_time_seconds{quantile="median"} 0.05$' \
    '^unbound_time_up_seconds 100.5' \
    '^unbound_mem_cache_rrset_bytes 4096$' \
    '^unbound_cache_count{cache="rrset"} 20$' \
    '^unbound_stat{name="num.query.tcp"} 1$' \
    '^unbound_response_time_seconds_bucket{le="2e-06"} 1$' \
    '^unbound_response_time_seconds_bucket{le="8e-06"} 4$' \
    '^unbound_response_time_seconds_bucket{le="+Inf"} 4$' \
    '^unbound_response_time_seconds_count 4$' \
    '^unbound_response_time_seconds_sum 0.5$' \
    '^# TYPE unbound_total_num_queries counter$' \
    '^# TYPE unbound_total_requestlist_avg gauge$' \
    '^# TYPE unbound_response_time_seconds histogram$'; do
    grep -qE "$expect" "$out" || fail "stats_to_prometheus: missing '$expect' in: $(cat "$out")"
  done
  # Families must be grouped: HELP for a name appears exactly once.
  [ "$(grep -c '^# HELP unbound_thread_num_queries ' "$out")" = 1 ] || fail "thread family emitted more than once"
  rm -f "$out"
  pass "stats_to_prometheus: valid exposition text, labels, grouped families, cumulative histogram"
}

t0_cycle_metrics_unit() {
  local out="$TEST_TMPDIR/upd-cycle-$$.prom" res
  res=$(docker run --rm --entrypoint /bin/bash "$UPDATER_IMAGE" -c '
    set -euo pipefail
    export STATE_DIR=/tmp/st RETRY_AFTER=1h
    . /usr/local/lib/unbound-autoupdate/log.sh
    . /usr/local/lib/unbound-autoupdate/state.sh
    . /usr/local/lib/unbound-autoupdate/metrics.sh
    state_init
    state_inc CYCLES_TEST; state_inc CYCLES_TEST
    [ "$(state_get CYCLES_TEST)" = 2 ] || { echo "state_inc failed: $(state_get CYCLES_TEST)"; exit 1; }
    self_quarantine_active "d1" && { echo "self quarantine should be inactive"; exit 1; }
    self_quarantine_set "d1"
    self_quarantine_active "d1" || { echo "self quarantine should be active"; exit 1; }
    _quarantine_window_open SELF_QUARANTINE_TS || { echo "window should be open"; exit 1; }
    _quarantine_window_open QUARANTINE_TS && { echo "image window should be closed"; exit 1; }
    state_set LAST_IMAGE_DIGEST "esitcparis/unbound-distroless@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    record_cycle rollback 42
    record_cycle up_to_date 3
    echo "===="
    cat /tmp/st/metrics.prom') || fail "cycle metrics unit failed: $res"
  printf '%s\n' "${res#*====$'\n'}" > "$out"
  promtool_check "$out" || fail "metrics.prom rejected by promtool: $(cat "$out")"
  local expect
  for expect in \
    '^unbound_autoupdate_last_cycle_status{status="up_to_date"} 1$' \
    '^unbound_autoupdate_last_cycle_status{status="rollback"} 0$' \
    '^unbound_autoupdate_last_cycle_duration_seconds 3$' \
    '^unbound_autoupdate_cycles_total{status="rollback"} 1$' \
    '^unbound_autoupdate_cycles_total{status="up_to_date"} 1$' \
    '^unbound_autoupdate_cycles_total{status="critical"} 0$' \
    '^unbound_autoupdate_quarantine_active{axis="self"} 1$' \
    '^unbound_autoupdate_quarantine_active{axis="image"} 0$' \
    '^unbound_autoupdate_target_image_info{digest="esitcparis/unbound-distroless@sha256:0000' \
    '^unbound_autoupdate_info{version="' \
    '^unbound_autoupdate_self_update_last_timestamp_seconds 0$' \
    '^unbound_autoupdate_last_cycle_timestamp_seconds [0-9]{10}$'; do
    grep -qE "$expect" "$out" || fail "cycle metrics: missing '$expect' in: $(cat "$out")"
  done
  rm -f "$out"
  pass "record_cycle persists status and counters and writes a valid metrics.prom"
}
```

Ajouter les deux noms dans `ALL_TESTS` après `t0_config_fingerprint_directory_unit`.

- [ ] **Step 3: Lancer, vérifier l'échec**

```bash
ONLY="t0_stats_to_prometheus_unit t0_cycle_metrics_unit" bash tests/updater.sh
```

Attendu : `metrics.sh: No such file or directory` pour le premier.

- [ ] **Step 4: Généraliser les quarantaines dans `state.sh`**

Remplacer, dans `updater/lib/state.sh`, tout ce qui va de `quarantine_set() {` jusqu'à la fin de `config_quarantine_active()` par :

```bash
# state_inc <key> — increment an integer counter (unset counts as 0).
state_inc() {
  local cur; cur=$(state_get "$1"); : "${cur:=0}"
  state_set "$1" $(( cur + 1 ))
}

# Three quarantine axes share one mechanism, keyed on what changed:
#   image  — QUARANTINE_DIGEST / QUARANTINE_TS          (a resolver image)
#   config — CONFIG_QUARANTINE_HASH / CONFIG_QUARANTINE_TS (a config fingerprint)
#   self   — SELF_QUARANTINE_DIGEST / SELF_QUARANTINE_TS  (a sidecar image)
# A quarantined value is not retried before RETRY_AFTER elapses; a DIFFERENT
# value on the same axis always gets a fresh attempt. A config-only failure
# has no image worth quarantining, and a broken sidecar image must not block
# resolver updates: hence separate axes.
_quarantine_set()   { state_set "$1" "$3"; state_set "$2" "$(date -u +%s)"; }
_quarantine_clear() { state_set "$1" ""; state_set "$2" ""; }
# _quarantine_window_open <tskey> — 0 while the axis's timestamp is set and
# RETRY_AFTER has not elapsed, whatever value is quarantined (metrics use it).
_quarantine_window_open() {
  local ts now
  ts=$(state_get "$1"); [ -n "$ts" ] || return 1
  now=$(date -u +%s)
  [ $(( now - ts )) -lt "$(to_seconds "${RETRY_AFTER:-24h}")" ]
}
_quarantine_active() {  # <valuekey> <tskey> <value>
  local v; v=$(state_get "$1")
  [ -n "$v" ] && [ "$v" = "$3" ] || return 1
  _quarantine_window_open "$2"
}

quarantine_set()           { _quarantine_set    QUARANTINE_DIGEST QUARANTINE_TS "$1"; }
quarantine_clear()         { _quarantine_clear  QUARANTINE_DIGEST QUARANTINE_TS; }
quarantine_active()        { _quarantine_active QUARANTINE_DIGEST QUARANTINE_TS "$1"; }
config_quarantine_set()    { _quarantine_set    CONFIG_QUARANTINE_HASH CONFIG_QUARANTINE_TS "$1"; }
config_quarantine_clear()  { _quarantine_clear  CONFIG_QUARANTINE_HASH CONFIG_QUARANTINE_TS; }
config_quarantine_active() { _quarantine_active CONFIG_QUARANTINE_HASH CONFIG_QUARANTINE_TS "$1"; }
self_quarantine_set()      { _quarantine_set    SELF_QUARANTINE_DIGEST SELF_QUARANTINE_TS "$1"; }
self_quarantine_clear()    { _quarantine_clear  SELF_QUARANTINE_DIGEST SELF_QUARANTINE_TS; }
self_quarantine_active()   { _quarantine_active SELF_QUARANTINE_DIGEST SELF_QUARANTINE_TS "$1"; }
```

Ajouter au-dessus de `ROLLBACK_FILE=` :

```bash
# The self-update helper's own override (Task 5), excluded from the compose
# file list exactly like ROLLBACK_FILE.
# shellcheck disable=SC2034
SELF_ROLLBACK_FILE="$STATE_DIR/self-rollback.yml"
```

et dans `discover.sh`, `_compose_file_args`, remplacer `if [ "$f" = "$ROLLBACK_FILE" ]; then continue; fi` par `if [ "$f" = "$ROLLBACK_FILE" ] || [ "$f" = "${SELF_ROLLBACK_FILE:-}" ]; then continue; fi`.

`t0_state_unit` existant doit rester vert : mêmes noms, mêmes sémantiques.

- [ ] **Step 5: Écrire `updater/lib/metrics.sh`**

```bash
#!/usr/bin/env bash
# Prometheus exposition: conversion of `unbound-control stats_noreset` and
# the sidecar's own cycle metrics. The text format's reference parser
# (promtool) is what the tests hold this output to.

METRICS_FILE="${STATE_DIR:-/var/lib/unbound-autoupdate}/metrics.prom"
_LIB_DIR=/usr/local/lib/unbound-autoupdate
CYCLE_STATUSES="up_to_date updated check_ok skipped blocked rollback critical error"

# stats_to_prometheus — stdin: key=value lines from unbound-control;
# stdout: exposition text. Families are buffered and printed grouped, each
# with HELP and TYPE exactly once. unbound's histogram buckets are counts per
# range; Prometheus wants cumulative counts per upper bound.
stats_to_prometheus() {
  awk -F= '
  function sanitize(s) { gsub(/[^a-zA-Z0-9_]/, "_", s); return s }
  function family(name, type, help) {
    if (!(name in ftype)) { ftype[name]=type; fhelp[name]=help; forder[++nf]=name }
  }
  function sample(name, labels, value,   line) {
    line = name
    if (labels != "") line = line "{" labels "}"
    fsamples[name] = fsamples[name] line " " value "\n"
  }
  function labelled(key, prefix, name, type, help, label,   l) {
    l = key; sub("^" prefix, "", l)
    family(name, type, help); sample(name, label "=\"" l "\"", $2)
  }
  {
    k=$1; v=$2
    if (k ~ /^thread[0-9]+\./) {
      t=k; sub(/^thread/, "", t); sub(/\..*$/, "", t)
      rest=k; sub(/^thread[0-9]+\./, "", rest)
      type = (rest ~ /requestlist|recursion|tcpusage/) ? "gauge" : "counter"
      n="unbound_thread_" sanitize(rest)
      family(n, type, "Per-thread value of " rest " from unbound-control stats.")
      sample(n, "thread=\"" t "\"", v); next
    }
    if (k ~ /^num\.query\.type\./)       { labelled(k, "num.query.type.",       "unbound_query_types_total",      "counter", "Queries received, by query type.", "type");   next }
    if (k ~ /^num\.query\.class\./)      { labelled(k, "num.query.class.",      "unbound_query_classes_total",    "counter", "Queries received, by query class.", "class"); next }
    if (k ~ /^num\.query\.opcode\./)     { labelled(k, "num.query.opcode.",     "unbound_query_opcodes_total",    "counter", "Queries received, by opcode.", "opcode");     next }
    if (k ~ /^num\.query\.flags\./)      { labelled(k, "num.query.flags.",      "unbound_query_flags_total",      "counter", "Queries received, by flag.", "flag");         next }
    if (k ~ /^num\.query\.aggressive\./) { labelled(k, "num.query.aggressive.", "unbound_query_aggressive_total", "counter", "Answers synthesised from cached NSEC/NSEC3 (RFC 8198), by rcode.", "rcode"); next }
    if (k ~ /^num\.answer\.rcode\./)     { labelled(k, "num.answer.rcode.",     "unbound_answer_rcodes_total",    "counter", "Answers sent, by rcode.", "rcode");           next }
    if (k == "num.answer.secure") { family("unbound_answers_secure_total", "counter", "Answers that validated as DNSSEC secure."); sample("unbound_answers_secure_total", "", v); next }
    if (k == "num.answer.bogus")  { family("unbound_answers_bogus_total",  "counter", "Answers that failed DNSSEC validation (bogus).");   sample("unbound_answers_bogus_total",  "", v); next }
    if (k == "num.rrset.bogus")   { family("unbound_rrset_bogus_total",    "counter", "RRsets marked bogus by the validator.");           sample("unbound_rrset_bogus_total",    "", v); next }
    if (k ~ /^histogram\./) {
      hi=k; sub(/^histogram\.[0-9]+\.[0-9]+\.to\./, "", hi)
      hcount[++nh]=v; hle[nh]=hi+0; next
    }
    if (k == "total.recursion.time.avg" || k == "total.recursion.time.median") {
      q=k; sub(/^total\.recursion\.time\./, "", q)
      if (q == "avg") ravg=v
      family("unbound_recursion_time_seconds", "gauge", "Recursion time of answers that needed recursion, in seconds.")
      sample("unbound_recursion_time_seconds", "quantile=\"" q "\"", v); next
    }
    if (k == "total.num.recursivereplies") rreplies=v
    if (k ~ /^total\./) {
      rest=k; sub(/^total\./, "", rest)
      type = (rest ~ /requestlist|tcpusage/) ? "gauge" : "counter"
      n="unbound_total_" sanitize(rest)
      family(n, type, "Value of total." rest " from unbound-control stats."); sample(n, "", v); next
    }
    if (k ~ /^time\.(now|up|elapsed)$/) {
      rest=k; sub(/^time\./, "", rest); n="unbound_time_" rest "_seconds"
      family(n, "gauge", "Unbound time." rest ", in seconds."); sample(n, "", v); next
    }
    if (k ~ /^mem\./) {
      rest=k; sub(/^mem\./, "", rest); n="unbound_mem_" sanitize(rest) "_bytes"
      family(n, "gauge", "Memory in use by " rest ", in bytes."); sample(n, "", v); next
    }
    if (k ~ /^(msg|rrset|infra|key)\.cache\.count$/) {
      c=k; sub(/\.cache\.count$/, "", c)
      family("unbound_cache_count", "gauge", "Number of entries per cache."); sample("unbound_cache_count", "cache=\"" c "\"", v); next
    }
    if (k == "unwanted.queries") { family("unbound_unwanted_queries_total", "counter", "Queries refused by access control.");            sample("unbound_unwanted_queries_total", "", v); next }
    if (k == "unwanted.replies") { family("unbound_unwanted_replies_total", "counter", "Unsolicited replies, a cache-poisoning signal."); sample("unbound_unwanted_replies_total", "", v); next }
    family("unbound_stat", "gauge", "Any other unbound-control statistic, by name.")
    sample("unbound_stat", "name=\"" k "\"", v)
  }
  END {
    for (i=1; i<=nf; i++) { n=forder[i]; printf "# HELP %s %s\n# TYPE %s %s\n%s", n, fhelp[n], n, ftype[n], fsamples[n] }
    if (nh > 0) {
      printf "# HELP unbound_response_time_seconds Recursion time distribution, in seconds.\n# TYPE unbound_response_time_seconds histogram\n"
      cum=0
      for (i=1; i<=nh; i++) { cum+=hcount[i]; printf "unbound_response_time_seconds_bucket{le=\"%g\"} %d\n", hle[i], cum }
      printf "unbound_response_time_seconds_bucket{le=\"+Inf\"} %d\n", cum
      printf "unbound_response_time_seconds_sum %g\n", (rreplies+0) * (ravg+0)
      printf "unbound_response_time_seconds_count %d\n", cum
    }
  }'
}

# write_cycle_metrics — rewrite metrics.prom from persisted state, atomically.
# Called at the end of every cycle (record_cycle) and by the self-update
# helper after it changed the sidecar itself.
write_cycle_metrics() {
  local tmp version self_digest status last_status last_ts last_dur target target_v s ts
  version=$(cat "$_LIB_DIR/VERSION" 2>/dev/null || echo dev)
  self_digest=$(docker image inspect "${SELF_IMAGE_ID:-}" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null) || self_digest=""
  last_status=$(state_get LAST_CYCLE_STATUS); : "${last_status:=error}"
  last_ts=$(state_get LAST_CYCLE_TS);         : "${last_ts:=0}"
  last_dur=$(state_get LAST_CYCLE_DURATION);  : "${last_dur:=0}"
  target=$(state_get LAST_IMAGE_DIGEST)
  target_v=""
  [ -n "$target" ] && target_v=$(docker image inspect "$target" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null) || true
  ts=$(state_get SELF_UPDATE_TS); : "${ts:=0}"

  tmp=$(mktemp "$STATE_DIR/.metrics.XXXXXX")
  {
    printf '# HELP unbound_autoupdate_info Sidecar version and image digest.\n# TYPE unbound_autoupdate_info gauge\n'
    printf 'unbound_autoupdate_info{version="%s",image_digest="%s"} 1\n' "$version" "${self_digest:-unknown}"
    printf '# HELP unbound_autoupdate_last_cycle_timestamp_seconds End of the last update cycle, unix time.\n# TYPE unbound_autoupdate_last_cycle_timestamp_seconds gauge\n'
    printf 'unbound_autoupdate_last_cycle_timestamp_seconds %s\n' "$last_ts"
    printf '# HELP unbound_autoupdate_last_cycle_duration_seconds Duration of the last update cycle.\n# TYPE unbound_autoupdate_last_cycle_duration_seconds gauge\n'
    printf 'unbound_autoupdate_last_cycle_duration_seconds %s\n' "$last_dur"
    printf '# HELP unbound_autoupdate_last_cycle_status Outcome of the last cycle, one-hot.\n# TYPE unbound_autoupdate_last_cycle_status gauge\n'
    for s in $CYCLE_STATUSES; do
      printf 'unbound_autoupdate_last_cycle_status{status="%s"} %d\n' "$s" "$([ "$s" = "$last_status" ] && echo 1 || echo 0)"
    done
    printf '# HELP unbound_autoupdate_cycles_total Cycles run since the state volume was created, by outcome.\n# TYPE unbound_autoupdate_cycles_total counter\n'
    for s in $CYCLE_STATUSES; do
      local c; c=$(state_get "CYCLES_${s^^}"); : "${c:=0}"
      printf 'unbound_autoupdate_cycles_total{status="%s"} %s\n' "$s" "$c"
    done
    printf '# HELP unbound_autoupdate_quarantine_active 1 while a failed image, configuration or sidecar image is held back.\n# TYPE unbound_autoupdate_quarantine_active gauge\n'
    printf 'unbound_autoupdate_quarantine_active{axis="image"} %d\n'  "$(_quarantine_window_open QUARANTINE_TS        && echo 1 || echo 0)"
    printf 'unbound_autoupdate_quarantine_active{axis="config"} %d\n' "$(_quarantine_window_open CONFIG_QUARANTINE_TS && echo 1 || echo 0)"
    printf 'unbound_autoupdate_quarantine_active{axis="self"} %d\n'   "$(_quarantine_window_open SELF_QUARANTINE_TS   && echo 1 || echo 0)"
    printf '# HELP unbound_autoupdate_target_image_info Image the resolver was last seen or deployed on.\n# TYPE unbound_autoupdate_target_image_info gauge\n'
    printf 'unbound_autoupdate_target_image_info{digest="%s",version="%s"} 1\n' "${target:-unknown}" "${target_v:-unknown}"
    printf '# HELP unbound_autoupdate_self_update_last_timestamp_seconds Last successful self-update, unix time (0 = never).\n# TYPE unbound_autoupdate_self_update_last_timestamp_seconds gauge\n'
    printf 'unbound_autoupdate_self_update_last_timestamp_seconds %s\n' "$ts"
  } > "$tmp"
  mv -f "$tmp" "$METRICS_FILE"
}

# record_cycle <status> <duration_seconds> — persist the outcome, bump its
# counter, rewrite metrics.prom. <status> must be one of CYCLE_STATUSES.
record_cycle() {
  local status="$1" duration="$2"
  case " $CYCLE_STATUSES " in *" $status "*) : ;; *) log_die "record_cycle: unknown status '$status'";; esac
  state_set LAST_CYCLE_STATUS "$status"
  state_set LAST_CYCLE_TS "$(date -u +%s)"
  state_set LAST_CYCLE_DURATION "$duration"
  state_inc "CYCLES_${status^^}"
  write_cycle_metrics
}
```

- [ ] **Step 6: Reconstruire, relancer les deux unitaires et `t0_state_unit`**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t0_stats_to_prometheus_unit t0_cycle_metrics_unit t0_state_unit" bash tests/updater.sh
```

Attendu : trois PASS. Si promtool rejette une ligne, corriger la conversion, pas l'attente du test.

- [ ] **Step 7: `finish` et trap unique dans l'orchestrateur**

Dans `updater/unbound-autoupdate` :

1. Après le sourcing de `verify.sh`, ajouter `# shellcheck source=updater/lib/metrics.sh` puis `. "$LIB/metrics.sh"`.
2. Juste après `flock -n 9 || { …; exit 2; }`, ajouter :

```bash
CYCLE_START=$(date -u +%s)
FINISHED=0
CANARY_ACTIVE=0

# finish <status> <code> — the ONLY way out of a cycle once the lock is held:
# persists the outcome and its counter, rewrites metrics.prom, exits.
finish() {
  FINISHED=1
  record_cycle "$1" $(( $(date -u +%s) - CYCLE_START ))
  exit "$2"
}

# One EXIT trap for the whole cycle. It tears down a live canary and, when
# the script died on its own (log_die, set -e) rather than through finish,
# records the cycle as an error so the staleness and failure alerts fire
# instead of the previous status lingering as if nothing had happened.
_on_exit() {
  local rc=$?
  [ "$CANARY_ACTIVE" = 1 ] && canary_down
  if [ "$FINISHED" = 0 ]; then
    record_cycle error $(( $(date -u +%s) - CYCLE_START )) || true
  fi
  exit "$rc"
}
trap _on_exit EXIT
```

3. Remplacer chaque sortie par `finish` :

| Ancien | Nouveau |
|---|---|
| `hc_fail "pull failed"; exit 1` | `hc_fail "pull failed"; finish blocked 1` |
| `hc_fail "config fingerprint failed"; exit 1` | `hc_fail "config fingerprint failed"; finish blocked 1` |
| `hc_success; exit 0` après `up to date` | `hc_success; finish up_to_date 0` |
| `hc_fail "quarantined image"; exit 2` | `hc_fail "quarantined image"; finish skipped 2` |
| `hc_fail "quarantined configuration"; exit 2` | `hc_fail "quarantined configuration"; finish skipped 2` |
| `hc_fail "major bump refused"; exit 2` | `hc_fail "major bump refused"; finish skipped 2` |
| `hc_fail "signature verification failed"; exit 1` | `hc_fail "signature verification failed"; finish blocked 1` |
| `hc_fail "preflight failed"; exit 1` | `hc_fail "preflight failed"; finish blocked 1` |
| `hc_fail "canary start failed"; exit 1` | `hc_fail "canary start failed"; finish blocked 1` |
| `hc_fail "canary validation failed"; exit 1` | `hc_fail "canary validation failed"; finish blocked 1` |
| `hc_success; exit 0` en mode check | `hc_success; finish check_ok 0` |
| `hc_success; exit 0` après `updated successfully` | `hc_success; finish updated 0` |
| `hc_fail "post-swap validation failed"; exit 1` (fin du script) | voir ci-dessous |

4. Supprimer `trap canary_down EXIT` et `trap - EXIT` ; à la place, `CANARY_ACTIVE=1` juste avant `if ! canary_up "$DECLARED"; then` et `CANARY_ACTIVE=0` juste après l'appel explicite `canary_down` qui suit `log_info "canary validated: …"`.

5. La fin du script (branche rollback) devient :

```bash
if [ "$rollback_ok" = 1 ] && [ -n "$TARGET_CONTAINER" ] \
   && probe=$(target_probe_ip) && wait_resolver "$probe" 45 && validate_resolver "$probe"; then
  … (inchangé : log + notify rollback)
  hc_fail "post-swap validation failed"
  finish rollback 1
else
  … (inchangé : log + notify critical)
  hc_fail "post-swap validation failed"
  finish critical 1
fi
```

- [ ] **Step 8: Vérifier sur les tests existants qui traversent chaque sortie**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t2_noop_second_cycle t3_config_change_triggers t7b_rollback_restores_previous_digest t4_invalid_conf_rejected" bash tests/updater.sh
```

Attendu : quatre PASS. Puis vérifier à la main qu'un cycle écrit bien le fichier : dans une fixture laissée en vie (commenter temporairement le trap RETURN d'un test, ou créer une fixture à la main), `updater_exec … cat /var/lib/unbound-autoupdate/metrics.prom` doit montrer `last_cycle_status{status="up_to_date"} 1` après un second cycle. Ne pas committer d'aménagement de test.

- [ ] **Step 9: shellcheck, commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning updater/lib/state.sh updater/lib/metrics.sh updater/lib/discover.sh updater/unbound-autoupdate tests/updater.sh tests/updater/lib.sh
git add updater/lib/state.sh updater/lib/metrics.sh updater/lib/discover.sh updater/unbound-autoupdate tests/updater.sh tests/updater/lib.sh
git commit -m "feat(updater): cycle outcome metrics, stats_noreset to Prometheus conversion, generic quarantine axes"
```

---

### Task 4a: Image Alpine 3.24, entrypoint `loop` / `once` / `check`, arrêt propre

**Files:**
- Modify: `updater/Dockerfile`
- Delete: `updater/VERSION`
- Modify: `updater/entrypoint.sh` (remplacé)
- Modify: `.hadolint.yaml`
- Test: `tests/updater.sh` (`t_modes`, `t_loop_sigterm`)

**Interfaces:**
- Consumes: `to_seconds`, `log_*`, `/usr/local/bin/unbound-autoupdate`.
- Produces: `entrypoint.sh` acceptant `loop` (défaut), `once`, `check`, `metrics` (Task 4b), `idle`, `self-update-apply` (Task 5). Variables `RUN_MODE`, `INTERVAL` (défaut `1h`), `SPLAY` (défaut `10%`, ou une durée absolue). `/usr/local/lib/unbound-autoupdate/VERSION` généré au build depuis `--build-arg UPDATER_VERSION` (défaut `dev`). Build-args `ALPINE_BASE`, `COSIGN_IMAGE`.

- [ ] **Step 1: Écrire les tests qui échouent**

Dans `tests/updater.sh`, avant `t1_image_update_actually_lands` :

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

  # An unknown mode is a hard, named error — not a silent loop.
  local rc=0
  out=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$UPDATER_IMAGE" bogus 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown mode was accepted"
  grep -q "unknown mode 'bogus'" <<<"$out" || fail "unknown mode not named: $out"
  # The image carries the version it was built with.
  out=$(docker run --rm --entrypoint cat "$UPDATER_IMAGE" /usr/local/lib/unbound-autoupdate/VERSION)
  [ -n "$out" ] || fail "VERSION file is empty"
  pass "unknown mode refused by name; VERSION file present ($out)"
}

t_loop_sigterm() {
  # loop mode sleeps between cycles; SIGTERM must interrupt that sleep, or
  # every `docker compose down` waits for Docker's 10 s kill timeout. The
  # container here is not compose-managed, so its first cycle fails fast
  # (discovery) and the loop goes to sleep — which is exactly what we stop.
  local name="upd-sigterm-$$" t0 t1
  docker run -d --name "$name" -e INTERVAL=1h -v /var/run/docker.sock:/var/run/docker.sock "$UPDATER_IMAGE" loop >/dev/null
  blocker_track "$name"
  sleep 6
  docker logs "$name" 2>&1 | grep -q 'next cycle in' || fail "loop did not reach its sleep: $(docker logs "$name" 2>&1 | tail -5)"
  t0=$(date +%s); docker stop "$name" >/dev/null; t1=$(date +%s)
  [ $(( t1 - t0 )) -lt 4 ] || fail "docker stop took $(( t1 - t0 ))s — SIGTERM is not reaching the sleep"
  docker rm -f "$name" >/dev/null 2>&1 || true
  pass "loop mode stops in under 4 s on SIGTERM"
}
```

Ajouter `t_modes` et `t_loop_sigterm` dans `ALL_TESTS` avant `t1_image_update_actually_lands`.

- [ ] **Step 2: Lancer, vérifier l'échec**

```bash
ONLY="t_modes t_loop_sigterm" bash tests/updater.sh
```

Attendu : `t_modes` échoue (`check mode did not announce itself`, le placeholder dort).

- [ ] **Step 3: Écrire `updater/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

# Base images are parameterised so CI can pin them by digest (the digests live
# in .build-state.json, kept current by upstream-check.yml, which also
# triggers a rebuild when they move). Local builds get the floating tags.
ARG ALPINE_BASE=alpine:3.24
ARG COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5

FROM ${COSIGN_IMAGE} AS cosign

FROM ${ALPINE_BASE}
ARG UPDATER_VERSION=dev
LABEL org.opencontainers.image.title="unbound-autoupdate" \
      org.opencontainers.image.description="Canary-tested automatic updater and Prometheus exporter for unbound-distroless" \
      org.opencontainers.image.source="https://github.com/ESITC-Paris/unbound-distroless" \
      org.opencontainers.image.version="${UPDATER_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="ESITC Paris"

# bash: arrays and `local -n` are used throughout. util-linux: flock.
# tini: loop mode must forward SIGTERM so `docker compose down` is prompt.
# busybox-extras: httpd (the /metrics endpoint) and nc.
RUN apk add --no-cache \
      bash docker-cli docker-cli-compose bind-tools curl ca-certificates \
      coreutils util-linux tini jq busybox-extras

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign

COPY lib/ /usr/local/lib/unbound-autoupdate/
COPY www/ /usr/local/lib/unbound-autoupdate/www/
COPY unbound-autoupdate entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/unbound-autoupdate /usr/local/bin/entrypoint.sh \
      /usr/local/lib/unbound-autoupdate/www/cgi-bin/metrics \
 && printf '%s\n' "$UPDATER_VERSION" > /usr/local/lib/unbound-autoupdate/VERSION

EXPOSE 9167

# The container runs as root on purpose: it needs the Docker socket, which is
# root-equivalent anyway. Documented in updater/README.md rather than hidden.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

`updater/www/cgi-bin/metrics` est créé en Task 4b ; pour que cette tâche construise, créer dès maintenant `updater/www/cgi-bin/metrics` avec le contenu provisoire :

```bash
#!/usr/bin/env bash
# Replaced in the metrics task.
printf 'Content-Type: text/plain\r\n\r\nnot implemented\n'
```

Supprimer `updater/VERSION` (`git rm updater/VERSION`). Dans `.hadolint.yaml`, ajouter à `ignored:` :

```yaml
  # DL3018 (pin apk versions): the sidecar's packages are governed by the
  # digest-pinned Alpine base (.build-state.json), same policy as DL3008.
  - DL3018
```

- [ ] **Step 4: Écrire `updater/entrypoint.sh`**

```bash
#!/usr/bin/env bash
# Mode dispatch and scheduling loop.
#   loop  (default)     — a cycle every INTERVAL, with SPLAY jitter
#   once                — exactly one cycle, then exit with its status
#   check               — one cycle that validates but never swaps
#   metrics             — serve /metrics for Prometheus; never runs a cycle
#   idle                — keep the container up without running anything,
#                         for `docker compose exec` maintenance and tests
#   self-update-apply   — internal: run by the ephemeral self-update helper
set -euo pipefail

LIB=/usr/local/lib/unbound-autoupdate
# shellcheck source=updater/lib/log.sh
. "$LIB/log.sh"
# shellcheck source=updater/lib/state.sh
. "$LIB/state.sh"

MODE="${1:-${RUN_MODE:-loop}}"
INTERVAL="${INTERVAL:-1h}"
SPLAY="${SPLAY:-10%}"
VERSION=$(cat "$LIB/VERSION" 2>/dev/null || echo dev)

# _delay — INTERVAL plus a random jitter of up to SPLAY, so a fleet of
# resolvers never all update in the same minute. SPLAY is either a
# percentage of INTERVAL ("10%") or an absolute duration ("5m").
_delay() {
  local base max
  base=$(to_seconds "$INTERVAL")
  case "$SPLAY" in
    *%) local pct="${SPLAY%\%}"
        case "$pct" in ''|*[!0-9]*) log_die "invalid SPLAY: $SPLAY";; esac
        max=$(( base * pct / 100 )) ;;
    *)  max=$(to_seconds "$SPLAY") ;;
  esac
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
  metrics)
    # shellcheck source=updater/lib/metrics.sh
    . "$LIB/metrics.sh"
    exec_metrics_server
    ;;
  idle)
    log_info "unbound-autoupdate $VERSION idle: no cycles will run"
    exec sleep infinity
    ;;
  self-update-apply)
    shift
    # shellcheck source=updater/lib/discover.sh
    . "$LIB/discover.sh"
    # shellcheck source=updater/lib/metrics.sh
    . "$LIB/metrics.sh"
    # shellcheck source=updater/lib/selfupdate.sh
    . "$LIB/selfupdate.sh"
    self_update_apply "$@"
    ;;
  loop)
    # Validate the schedule once, up front: a typo must stop the container
    # now, not after the first cycle has run.
    _delay >/dev/null
    log_info "unbound-autoupdate $VERSION starting: interval=$INTERVAL splay=$SPLAY"
    while true; do
      # A failing cycle must not kill the loop: it has already notified, and
      # the next tick retries. Only a human decision stops the sidecar.
      /usr/local/bin/unbound-autoupdate || log_warn "cycle exited $? — continuing"
      d=$(_delay)
      log_info "next cycle in ${d}s"
      sleep "$d" &
      wait $!   # `wait` on a background sleep so tini's SIGTERM lands promptly
    done
    ;;
  *)
    log_die "unknown mode '$MODE' (expected loop, once, check, metrics or idle)"
    ;;
esac
```

`exec_metrics_server` et `self_update_apply` n'existent pas encore : ajouter en fin de `updater/lib/metrics.sh` un stub provisoire remplacé en Task 4b :

```bash
exec_metrics_server() { log_die "metrics mode: not implemented yet"; }
```

`selfupdate.sh` n'existe pas avant la Task 5 ; le sourcing dans la branche `self-update-apply` n'est évalué qu'à l'appel, donc l'image construit et les autres modes fonctionnent.

- [ ] **Step 5: Reconstruire, relancer**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t_modes t_loop_sigterm t0_image_sane" bash tests/updater.sh
```

Attendu : PASS partout. Si `t_loop_sigterm` dépasse 4 s : vérifier que `wait $!` est bien utilisé et que tini est PID 1 (`docker inspect` → `Path` = `/sbin/tini`).

- [ ] **Step 6: hadolint, shellcheck, commit**

```bash
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d < updater/Dockerfile
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning updater/entrypoint.sh updater/lib/metrics.sh updater/www/cgi-bin/metrics tests/updater.sh
git add updater/Dockerfile updater/entrypoint.sh updater/www updater/lib/metrics.sh .hadolint.yaml tests/updater.sh
git rm -q updater/VERSION
git commit -m "feat(updater): Alpine 3.24 image, loop/once/check modes with prompt shutdown, build-time VERSION"
```

---

### Task 4b: Mode `metrics` — httpd, CGI de scrape

**Files:**
- Modify: `updater/lib/metrics.sh` (`exec_metrics_server`)
- Create: `updater/www/cgi-bin/metrics` (remplace le stub), `updater/www/httpd.conf.tmpl`
- Test: `tests/updater.sh` (`t_metrics_scrape`)

**Interfaces:**
- Consumes: `discover_target_container` (Task 1), `stats_to_prometheus`, `METRICS_FILE` (Task 3).
- Produces: `exec_metrics_server` — `exec` de `httpd -f` sur `METRICS_PORT` (défaut `9167`) ; `/metrics` répond toujours HTTP 200 avec `unbound_exporter_scrape_success` et `unbound_exporter_scrape_duration_seconds`.

- [ ] **Step 1: Écrire le test qui échoue**

Dans `tests/updater.sh`, après `t_loop_sigterm` :

```bash
t_metrics_scrape() {
  local dir="$TEST_TMPDIR/upd-metrics-$$"
  trap 'fixture_destroy "$dir"' RETURN
  fixture_create "$dir" "$MOVING_REF"
  updater_run "$dir" >/dev/null || fail "baseline cycle failed"

  local addr out="$TEST_TMPDIR/upd-metrics-$$.prom" _i
  addr=$(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" port metrics 9167)
  [ -n "$addr" ] || fail "metrics service publishes no port"
  for _i in $(seq 1 15); do
    curl -fsS -o "$out" "http://$addr/metrics" 2>/dev/null && break
    sleep 1
  done
  [ -s "$out" ] || fail "/metrics never answered on $addr: $(docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" logs metrics 2>&1 | tail -5)"
  promtool_check "$out" || fail "/metrics rejected by promtool: $(head -40 "$out")"
  local expect
  for expect in \
    '^unbound_exporter_scrape_success 1$' \
    '^unbound_exporter_scrape_duration_seconds [0-9.]+$' \
    '^unbound_total_num_queries [0-9]+$' \
    '^unbound_query_types_total{type="A"} [0-9]+$' \
    '^unbound_response_time_seconds_bucket{le="\+Inf"} [0-9]+$' \
    '^unbound_time_up_seconds [0-9.]+$' \
    '^unbound_autoupdate_last_cycle_status{status="up_to_date"} 1$' \
    '^unbound_autoupdate_cycles_total{status="up_to_date"} 1$' \
    '^unbound_autoupdate_target_image_info{digest="esitcparis/unbound-distroless@sha256:'; do
    grep -qE "$expect" "$out" || fail "/metrics: missing '$expect' in: $(head -60 "$out")"
  done
  pass "/metrics serves unbound statistics and sidecar cycle metrics, promtool-clean"

  # The resolver stopped: the scrape must still answer 200 with the sidecar
  # metrics and say the unbound part failed — never a 5xx or a hang.
  docker compose -p "$(fixture_project "$dir")" --project-directory "$dir" -f "$dir/docker-compose.yml" stop unbound >/dev/null 2>&1
  local code
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 20 "http://$addr/metrics")
  [ "$code" = 200 ] || fail "/metrics returned HTTP $code with the resolver down"
  grep -q '^unbound_exporter_scrape_success 0$' "$out" || fail "scrape_success not 0 with the resolver down: $(head -20 "$out")"
  grep -q '^unbound_autoupdate_last_cycle_status' "$out" || fail "sidecar metrics missing with the resolver down"
  promtool_check "$out" || fail "degraded /metrics rejected by promtool"
  rm -f "$out"
  pass "/metrics degrades to scrape_success=0 with HTTP 200 when the resolver is down"
}
```

Ajouter `t_metrics_scrape` dans `ALL_TESTS` après `t_loop_sigterm`.

- [ ] **Step 2: Lancer, vérifier l'échec**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY=t_metrics_scrape bash tests/updater.sh
```

Attendu : `/metrics never answered` (le mode `metrics` meurt sur le stub `not implemented`).

- [ ] **Step 3: `exec_metrics_server`**

Remplacer le stub en fin de `updater/lib/metrics.sh` par :

```bash
# exec_metrics_server — busybox httpd in the foreground, docroot www/, with
# a proxy rule so the public path is /metrics rather than /cgi-bin/metrics.
# httpd is the process; tini forwards SIGTERM to it.
exec_metrics_server() {
  local port="${METRICS_PORT:-9167}" conf=/tmp/httpd.conf
  case "$port" in ''|*[!0-9]*) log_die "invalid METRICS_PORT: $port";; esac
  sed "s/@PORT@/$port/" "$_LIB_DIR/www/httpd.conf.tmpl" > "$conf"
  log_info "unbound-autoupdate $(cat "$_LIB_DIR/VERSION" 2>/dev/null || echo dev) metrics mode: serving /metrics on port $port"
  exec httpd -f -p "$port" -h "$_LIB_DIR/www" -c "$conf"
}
```

`updater/www/httpd.conf.tmpl` :

```
P:/metrics:http://127.0.0.1:@PORT@/cgi-bin/metrics
```

- [ ] **Step 4: Le CGI `updater/www/cgi-bin/metrics`**

```bash
#!/usr/bin/env bash
# Prometheus scrape endpoint, run by busybox httpd per request.
# Always answers 200: when the resolver cannot be reached, the sidecar's own
# metrics are still served and unbound_exporter_scrape_success is 0. A
# scrape must never hang or 5xx because DNS is down — that is precisely
# when the metrics matter.
set -uo pipefail

LIB=/usr/local/lib/unbound-autoupdate
# shellcheck source=updater/lib/log.sh
. "$LIB/log.sh"
# shellcheck source=updater/lib/state.sh
. "$LIB/state.sh"
# shellcheck source=updater/lib/discover.sh
. "$LIB/discover.sh"
# shellcheck source=updater/lib/metrics.sh
. "$LIB/metrics.sh"

printf 'Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n\r\n'
start=$(date +%s.%N)
ok=0

# Discovery and the exec run in a subshell: discover_target_container dies
# (exit) when it cannot find the resolver, and that must not end the scrape.
if stats=$( { discover_target_container \
              && timeout 10 docker exec "$TARGET_CONTAINER" \
                   /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset; } 2>/dev/null ); then
  if [ -n "$stats" ]; then
    stats_to_prometheus <<<"$stats"
    ok=1
  fi
fi

[ -r "$METRICS_FILE" ] && cat "$METRICS_FILE"

printf '# HELP unbound_exporter_scrape_success 1 when unbound-control stats were collected on this scrape.\n# TYPE unbound_exporter_scrape_success gauge\n'
printf 'unbound_exporter_scrape_success %d\n' "$ok"
printf '# HELP unbound_exporter_scrape_duration_seconds Time spent collecting this scrape.\n# TYPE unbound_exporter_scrape_duration_seconds gauge\n'
printf 'unbound_exporter_scrape_duration_seconds %s\n' "$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.3f", b - a }')"
```

`timeout` vient de coreutils (déjà installé). Le script doit être exécutable (le `chmod` du Dockerfile le couvre).

- [ ] **Step 5: Reconstruire, relancer**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t_metrics_scrape t_modes" bash tests/updater.sh
```

Attendu : PASS. Si `promtool` se plaint d'une métrique du CGI, corriger le CGI. Si le scrape pend avec le résolveur arrêté, c'est `timeout 10` qui manque.

- [ ] **Step 6: shellcheck, commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning updater/lib/metrics.sh updater/www/cgi-bin/metrics tests/updater.sh
git add updater/lib/metrics.sh updater/www tests/updater.sh
git commit -m "feat(updater): metrics mode serving /metrics via busybox httpd and a stats_noreset CGI"
```

---

### Task 5: Self-update par conteneur éphémère

**Files:**
- Create: `updater/lib/selfupdate.sh`
- Modify: `updater/unbound-autoupdate` (hook après `up to date` et `updated`)
- Test: `tests/updater.sh` (`t_self_update_applies`, `t_self_update_rolls_back`), `tests/updater/lib.sh` (`fixture_service_image_id`)

**Interfaces:**
- Consumes: `discover_target` (globales `SELF_ID`, `SELF_IMAGE_ID`, `COMPOSE_*`, `COMPOSE_FILE_ARGS`), `compose`, `image_version_label`, `verify_image`, `self_quarantine_*`, `write_cycle_metrics`, `notify`, `hc_fail`, `_label`, `_compose_file_args`, `SELF_ROLLBACK_FILE`.
- Produces: `self_update` — 0 quand il n'y a rien à faire ou que le helper est lancé (`SELF_UPDATE_LAUNCHED=1`), 1 quand la signature est refusée ou le helper ne démarre pas. `self_update_apply <project> <workdir> <old_digest> <new_digest> <files_csv> <self_service> [services…]` — exécuté dans le helper, ne revient jamais (exit 0/1). Variable `SELF_UPDATE` (défaut `1`). Les helpers portent le label `unbound-autoupdate.helper=1`.
- Produces (tests) : `fixture_service_image_id <dir> <service>` — l'ID d'image du conteneur d'un service.

- [ ] **Step 1: Helper de test**

Dans `tests/updater/lib.sh`, après `running_ref` :

```bash
# fixture_service_image_id <dir> <service> — image ID the service's container
# runs, or empty when it has no running container.
fixture_service_image_id() {
  local cid
  cid=$(docker compose -p "$(fixture_project "$1")" --project-directory "$1" \
        -f "$1/docker-compose.yml" ps -q "$2" 2>/dev/null | head -1)
  [ -n "$cid" ] || { echo ""; return 0; }
  docker inspect "$cid" --format '{{.Image}}' 2>/dev/null || echo ""
}
```

- [ ] **Step 2: Écrire les deux tests qui échouent**

Dans `tests/updater.sh`, après `t8_major_bump_refused` :

```bash
t_self_update_applies() {
  # The sidecar's own services are declared on a throwaway-registry tag. A
  # newer, key-signed image appears under that tag; at the end of an
  # up-to-date cycle the sidecar must verify it and hand the recreation to
  # an ephemeral helper running the NEW image, because a `compose up` run
  # from inside the container being replaced dies when Compose stops it.
  local dir="$TEST_TMPDIR/upd-selfup-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 v2
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local id1; id1=$(fixture_service_image_id "$dir" updater)
  [ -n "$id1" ] || fail "setup: updater service not running"

  # Same tag, new bits, signed with the test key.
  v2=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"2\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"
  local id2; id2=$(docker image inspect "$v2" --format '{{.Id}}')
  [ "$id1" != "$id2" ] || fail "setup: v1 and v2 have the same image id"

  local out
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "cycle with a pending self-update failed: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not launched: $out"

  local _i
  for _i in $(seq 1 30); do
    [ "$(fixture_service_image_id "$dir" updater)" = "$id2" ] \
      && [ "$(fixture_service_image_id "$dir" metrics)" = "$id2" ] && break
    sleep 3
  done
  [ "$(fixture_service_image_id "$dir" updater)" = "$id2" ] || fail "updater service is not on the new image after 90s"
  [ "$(fixture_service_image_id "$dir" metrics)" = "$id2" ] || fail "metrics service is not on the new image after 90s"
  sleep 3
  [ -z "$(docker ps -aq --filter label=unbound-autoupdate.helper=1)" ] || fail "the apply helper container was left behind"
  updater_exec "$dir" grep -q '^SELF_UPDATE_TS=[0-9]' /var/lib/unbound-autoupdate/state.env \
    || fail "SELF_UPDATE_TS not recorded"
  updater_exec "$dir" grep -qE '^unbound_autoupdate_self_update_last_timestamp_seconds [0-9]{10}$' /var/lib/unbound-autoupdate/metrics.prom \
    || fail "metrics.prom does not reflect the self-update"
  pass "self-update: a key-signed newer sidecar image is applied to both services by the ephemeral helper"
}

t_self_update_rolls_back() {
  # The newer image is signed and pulls fine, but the updater container
  # built from it dies at start: its entrypoint no longer knows the fixture's
  # `idle` mode. The breakage is deliberately confined to that mode so the
  # helper (which runs on the same new image, in self-update-apply mode) and
  # the metrics service both work — this test is about the helper noticing
  # a dead sidecar, pinning both services back to the previous digest, and
  # quarantining the new digest so the next cycle does not try again.
  local dir="$TEST_TMPDIR/upd-selfrb-$$"
  trap 'fixture_destroy "$dir"; registry_down' RETURN
  registry_up
  local v1 v2
  v1=$(registry_publish "FROM $UPDATER_IMAGE
LABEL test.selfupdate=\"1\"" "unbound-autoupdate:1")
  FIXTURE_UPDATER_IMAGE="$v1" fixture_create "$dir" "$MOVING_REF"
  registry_forward "$dir"
  cosign_test_keys "$dir"
  local id1; id1=$(fixture_service_image_id "$dir" updater)

  v2=$(registry_publish "FROM $UPDATER_IMAGE
RUN sed -i 's/^  idle)\$/  idle-gone)/' /usr/local/bin/entrypoint.sh
LABEL test.selfupdate=\"broken\"" "unbound-autoupdate:1")
  registry_sign "$dir" "$v2"
  local d2; d2=$(docker image inspect "$v2" --format '{{index .RepoDigests 0}}')

  local out
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "cycle failed before launching the helper: $out"
  grep -q 'launching the apply helper' <<<"$out" || fail "self-update was not launched: $out"

  # The helper waits up to 30 s before rolling back; give it time.
  local _i
  for _i in $(seq 1 40); do
    updater_exec "$dir" grep -q "^SELF_QUARANTINE_DIGEST=$d2\$" /var/lib/unbound-autoupdate/state.env 2>/dev/null && break
    sleep 3
  done
  updater_exec "$dir" grep -q "^SELF_QUARANTINE_DIGEST=$d2\$" /var/lib/unbound-autoupdate/state.env \
    || fail "the broken sidecar image was not quarantined: $(updater_exec "$dir" cat /var/lib/unbound-autoupdate/state.env 2>/dev/null)"
  [ "$(fixture_service_image_id "$dir" updater)" = "$id1" ] || fail "updater service was not rolled back to the previous image"
  [ "$(fixture_service_image_id "$dir" metrics)" = "$id1" ] || fail "metrics service was not rolled back to the previous image"
  updater_exec "$dir" grep -q '^unbound_autoupdate_quarantine_active{axis="self"} 1$' /var/lib/unbound-autoupdate/metrics.prom \
    || fail "metrics.prom does not show the self quarantine"
  # And the next cycle must deliberately leave it alone.
  out=$(updater_run "$dir" COSIGN_PUBLIC_KEY="$TEST_PUBKEY" COSIGN_IGNORE_TLOG=1 2>&1) || fail "cycle after a self-rollback failed: $out"
  grep -q 'quarantined after a failed self-update' <<<"$out" || fail "quarantined sidecar image was retried: $out"
  pass "self-update: a sidecar image that cannot start is rolled back on both services and quarantined"
}
```

Ajouter les deux noms dans `ALL_TESTS` après `t8_major_bump_refused`.

- [ ] **Step 3: Lancer, vérifier l'échec**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY=t_self_update_applies bash tests/updater.sh
```

Attendu : `self-update was not launched` (aucun message ; l'orchestrateur ignore encore son image).

- [ ] **Step 4: Écrire `updater/lib/selfupdate.sh`**

```bash
#!/usr/bin/env bash
# Self-update of the sidecar. Detection and the guards run inside the
# sidecar at the end of a successful cycle; the recreation itself runs in
# an EPHEMERAL HELPER container started from the new, verified image. A
# `compose up -d` issued from the container being replaced dies the moment
# Compose stops that container — before the new one is started — so the
# only correct place to run it is outside.

SELF_UPDATE="${SELF_UPDATE:-1}"
SELF_UPDATE_LAUNCHED=0

# _self_state_mount — a -v argument giving a helper this sidecar's state
# volume (or bind mount) at the same STATE_DIR path.
_self_state_mount() {
  local name src
  name=$(docker inspect "$SELF_ID" --format "{{range .Mounts}}{{if eq .Destination \"$STATE_DIR\"}}{{.Name}}{{end}}{{end}}")
  if [ -n "$name" ]; then printf '%s:%s\n' "$name" "$STATE_DIR"; return 0; fi
  src=$(docker inspect "$SELF_ID" --format "{{range .Mounts}}{{if eq .Destination \"$STATE_DIR\"}}{{.Source}}{{end}}{{end}}")
  [ -n "$src" ] || return 1
  printf '%s:%s\n' "$src" "$STATE_DIR"
}

# _compose_files_csv — COMPOSE_FILE_ARGS (-f a -f b) back to "a,b".
_compose_files_csv() {
  local i csv=""
  for (( i = 1; i < ${#COMPOSE_FILE_ARGS[@]}; i += 2 )); do csv="$csv,${COMPOSE_FILE_ARGS[$i]}"; done
  printf '%s\n' "${csv#,}"
}

# self_update — run at the end of a cycle that ended "up to date" or
# "updated"; never after a failure and never in check mode.
#   0: nothing to do, deliberately skipped, or helper launched (SELF_UPDATE_LAUNCHED=1)
#   1: the new image failed verification or the helper could not start —
#      a supply-chain incident the caller must report as a failed cycle.
self_update() {
  SELF_UPDATE_LAUNCHED=0
  [ "$SELF_UPDATE" = 1 ] || return 0

  local self_service running cfg self_ref declared s
  self_service=$(_label "$SELF_ID" com.docker.compose.service)
  running=$(docker image inspect "$SELF_IMAGE_ID" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null) || running=""
  if [ -z "$running" ]; then
    log_info "self-update: my image carries no repository digest (locally built) — skipped"
    return 0
  fi

  cfg=$(compose config --format json) || { log_warn "self-update: docker compose config failed — skipped"; return 0; }
  self_ref=$(jq -r --arg s "$self_service" '.services[$s].image // empty' <<<"$cfg")
  [ -n "$self_ref" ] || { log_warn "self-update: service '$self_service' declares no image — skipped"; return 0; }

  # Every service of the project on the same declared image moves together
  # (the loop and the metrics service). Own service first: the helper waits
  # on it.
  local ordered=("$self_service")
  while read -r s; do
    [ -n "$s" ] && [ "$s" != "$self_service" ] && ordered+=("$s")
  done < <(jq -r --arg r "$self_ref" '.services | to_entries[] | select(.value.image == $r) | .key' <<<"$cfg")

  local pull_out
  if ! pull_out=$(compose pull --quiet "$self_service" 2>&1); then
    log_warn "self-update: docker compose pull failed — skipped"
    printf '%s\n' "$pull_out" >&2
    return 0
  fi
  declared=$(docker image inspect "$self_ref" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null) || declared=""
  [ -n "$declared" ] || { log_warn "self-update: '$self_ref' has no repository digest after pull — skipped"; return 0; }
  [ "$declared" != "$running" ] || return 0

  if self_quarantine_active "$declared"; then
    log_warn "self-update: $declared is quarantined after a failed self-update — not retrying yet"
    return 0
  fi

  local old_v new_v
  old_v=$(image_version_label "$running"); new_v=$(image_version_label "$declared")
  if [ -n "$old_v" ] && [ -n "$new_v" ] && [ "${old_v%%.*}" != "${new_v%%.*}" ] && [ "${ALLOW_MAJOR:-0}" != 1 ]; then
    log_warn "self-update: major version bump $old_v -> $new_v refused (set ALLOW_MAJOR=1 to accept)"
    notify skipped "sidecar major version bump not applied" "The declared sidecar image moves unbound-autoupdate from $old_v to $new_v. Major bumps are a deliberate human decision; set ALLOW_MAJOR=1 to allow them."
    return 0
  fi

  if ! verify_image "$declared"; then
    log_error "self-update: cosign verification FAILED for $declared — refusing to replace myself"
    notify blocked "sidecar signature verification FAILED" "Sidecar image $declared is not signed by the expected identity. The sidecar keeps running $running. Investigate immediately: an unsigned sidecar image in the registry is a supply-chain incident."
    return 1
  fi
  log_info "self-update: cosign signature verified for $declared"

  local state_mount
  state_mount=$(_self_state_mount) || { log_warn "self-update: cannot find my state volume — skipped"; return 0; }
  local mounts=(-v /var/run/docker.sock:/var/run/docker.sock -v "$COMPOSE_WORKDIR:$COMPOSE_WORKDIR:ro" -v "$state_mount")
  local i f
  for (( i = 1; i < ${#COMPOSE_FILE_ARGS[@]}; i += 2 )); do
    f="${COMPOSE_FILE_ARGS[$i]}"
    case "$f" in "$COMPOSE_WORKDIR"/*) : ;; *) mounts+=(-v "$f:$f:ro") ;; esac
  done

  log_info "self-update: $running -> $declared; launching the apply helper for: ${ordered[*]}"
  if ! docker run -d --rm --label unbound-autoupdate.helper=1 \
        "${mounts[@]}" \
        -e WEBHOOK_URL -e HC_URL -e NOTIFY_HOST -e RETRY_AFTER -e "STATE_DIR=$STATE_DIR" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$declared" self-update-apply "$COMPOSE_PROJECT" "$COMPOSE_WORKDIR" "$running" "$declared" \
        "$(_compose_files_csv)" "${ordered[@]}" >/dev/null; then
    log_error "self-update: could not launch the apply helper"
    notify blocked "sidecar self-update could not start" "The helper container for $declared could not be started. The sidecar keeps running $running."
    return 1
  fi
  SELF_UPDATE_LAUNCHED=1
  return 0
}

# self_update_apply <project> <workdir> <old_digest> <new_digest> <files_csv> <self_service> [services…]
# Runs in the ephemeral helper, on the NEW image. Never returns.
self_update_apply() {
  COMPOSE_PROJECT="$1"; COMPOSE_WORKDIR="$2"
  local old="$3" new="$4" files="$5"; shift 5
  local services=("$@") self_service="$1" s cid out ok=1
  state_init
  _compose_file_args "$files"

  log_info "self-update helper: recreating ${services[*]} on $new"
  out=$(compose up -d --no-deps "${services[@]}" 2>&1) || ok=0
  if [ "$ok" = 0 ]; then
    log_error "self-update helper: docker compose up failed"
    printf '%s\n' "$out" >&2
  fi

  # The new containers must be running, and still running with no restart,
  # 30 s later: a sidecar that dies at start would otherwise pass a
  # single instant check.
  if [ "$ok" = 1 ]; then
    local deadline healthy
    deadline=$(( $(date -u +%s) + 30 ))
    while :; do
      healthy=1
      for s in "${services[@]}"; do
        cid=$(compose ps -q "$s" 2>/dev/null | head -1)
        if [ -z "$cid" ] \
           || [ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null)" != true ] \
           || [ "$(docker inspect "$cid" --format '{{.RestartCount}}' 2>/dev/null)" != 0 ]; then
          healthy=0
        fi
      done
      [ "$(date -u +%s)" -ge "$deadline" ] && break
      sleep 3
    done
    [ "$healthy" = 1 ] || { ok=0; log_error "self-update helper: the new sidecar is not running 30 s after recreation"; }
  fi

  if [ "$ok" = 1 ]; then
    self_quarantine_clear
    state_set SELF_UPDATE_TS "$(date -u +%s)"
    write_cycle_metrics
    log_info "self-update helper: sidecar now runs $new (services: ${services[*]})"
    notify updated "sidecar updated" "unbound-autoupdate moved from $old to $new (unbound-autoupdate $(image_version_label "$new")) and its services (${services[*]}) are running."
    exit 0
  fi

  log_error "self-update helper: rolling ${services[*]} back to $old"
  COMPOSE_EXTRA_FILE="$SELF_ROLLBACK_FILE"
  {
    printf 'services:\n'
    for s in "${services[@]}"; do printf '  %s:\n    image: %s\n' "$s" "$old"; done
  } > "$COMPOSE_EXTRA_FILE"
  local rb_ok=1
  out=$(compose up -d --no-deps "${services[@]}" 2>&1) || rb_ok=0
  unset COMPOSE_EXTRA_FILE
  [ "$rb_ok" = 1 ] || { log_error "self-update helper: rollback compose up failed"; printf '%s\n' "$out" >&2; }
  self_quarantine_set "$new"
  write_cycle_metrics
  if [ "$rb_ok" = 1 ]; then
    notify critical "sidecar self-update FAILED — rolled back" "The new sidecar image $new did not come up. Services ${services[*]} were pinned back to $old. $new is quarantined for RETRY_AFTER=${RETRY_AFTER:-24h}. The compose file still declares the failing tag."
  else
    notify critical "CRITICAL: sidecar self-update FAILED and rollback failed" "Neither $new nor $old could be brought up for ${services[*]}. Automatic updates are DOWN on this host. MANUAL INTERVENTION REQUIRED."
  fi
  hc_fail "self-update failed"
  exit 1
}
```

- [ ] **Step 5: Brancher l'orchestrateur**

Dans `updater/unbound-autoupdate` : sourcer `selfupdate.sh` après `metrics.sh` (`# shellcheck source=updater/lib/selfupdate.sh`). Remplacer la sortie « up to date » :

```bash
if [ "$image_changed" = 0 ] && [ "$conf_changed" = 0 ] && [ "$CHECK_ONLY" != 1 ]; then
  log_info "up to date ($RUNNING)"
  if self_update; then hc_success; finish up_to_date 0; fi
  hc_fail "sidecar self-update refused"
  finish blocked 1
fi
```

et la sortie « updated » :

```bash
  notify updated "updated successfully" "…(inchangé)…"
  if self_update; then hc_success; finish updated 0; fi
  hc_fail "sidecar self-update refused"
  finish blocked 1
```

Le mode `check` n'appelle pas `self_update`.

- [ ] **Step 6: Reconstruire, relancer**

```bash
docker build -t unbound-autoupdate:test updater/ && ONLY="t_self_update_applies t_self_update_rolls_back t2_noop_second_cycle t1_image_update_actually_lands" bash tests/updater.sh
```

Attendu : quatre PASS. `t2` et `t1` prouvent que le self-update sur une image locale (sans digest) est un no-op silencieux.

Pièges connus : (1) si le helper ne trouve pas les fichiers compose, vérifier que `$dir` est monté dans le helper au même chemin (`-v "$COMPOSE_WORKDIR:$COMPOSE_WORKDIR:ro"`) ; (2) si `compose ps -q` renvoie l'ancien conteneur, c'est que `compose up` n'a pas recréé : les deux services doivent partager l'image déclarée **exactement** (même chaîne) ; (3) ne jamais « corriger » un test en retirant une assertion sur l'état.

- [ ] **Step 7: shellcheck, commit**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning updater/lib/selfupdate.sh updater/unbound-autoupdate updater/entrypoint.sh tests/updater.sh tests/updater/lib.sh
git add updater/lib/selfupdate.sh updater/unbound-autoupdate tests/updater.sh tests/updater/lib.sh
git commit -m "feat(updater): self-update through an ephemeral helper, with rollback and quarantine"
```

---

### Task 6: Versions, digests, moniteur, CI et workflow de publication du sidecar

**Files:**
- Modify: `versions.env`, `.build-state.json`
- Modify: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/upstream-check.yml`
- Create: `.github/workflows/updater.yml`
- Test: actionlint (image épinglée) + `bash -n` + un test bash de la logique de décision extraite dans un script

**Interfaces:**
- Consumes: `updater/Dockerfile` build-args `ALPINE_BASE`, `COSIGN_IMAGE`, `UPDATER_VERSION` (Task 4a).
- Produces: `.github/scripts/decide-updates.sh` — logique de décision du moniteur, testable hors GitHub : lit `versions.env`, `.build-state.json` et les variables `LATEST`, `NEW_DEBIAN`, `NEW_DISTROLESS`, `NEW_ALPINE`, `NEW_COSIGN`, écrit `action=` et `updater_action=` sur stdout. Tags `updater-vX.Y.Z-rN`. Images `esitcparis/unbound-autoupdate` et `ghcr.io/esitc-paris/unbound-autoupdate`.

- [ ] **Step 1: Test de la décision, qui échoue**

Créer `tests/monitor.sh` :

```bash
#!/usr/bin/env bash
# Unit test for the update monitor's decision logic (.github/scripts/decide-updates.sh).
# Runs anywhere: no network, no docker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/.github/scripts/decide-updates.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/versions.env" <<'ENV'
UNBOUND_VERSION=1.26.0
UNBOUND_SHA256=abc
REVISION=3
UPDATER_VERSION=1.0.0
UPDATER_REVISION=0
ENV
cat > "$tmp/.build-state.json" <<'JSON'
{ "debian": "sha256:d1", "distroless": "sha256:s1", "alpine": "sha256:a1", "cosign": "sha256:c1" }
JSON

decide() {  # decide <latest> <debian> <distroless> <alpine> <cosign>
  ( cd "$tmp" && LATEST="$1" NEW_DEBIAN="$2" NEW_DISTROLESS="$3" NEW_ALPINE="$4" NEW_COSIGN="$5" bash "$SCRIPT" )
}

out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
[ "$out" = $'action=none\nupdater_action=none' ] || fail "all unchanged: $out"
pass "nothing changed → none/none"

out=$(decide 1.27.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
grep -qx 'action=version' <<<"$out" || fail "new unbound version: $out"
grep -qx 'updater_action=none' <<<"$out" || fail "new unbound version must not touch the sidecar: $out"
pass "newer unbound → version/none"

out=$(decide 1.25.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
grep -qx 'action=none' <<<"$out" || fail "older upstream must be ignored (monotonicity): $out"
pass "older upstream → none (monotonicity guard)"

out=$(decide 1.26.0 sha256:d2 sha256:s1 sha256:a1 sha256:c1)
grep -qx 'action=revision' <<<"$out" || fail "debian digest change: $out"
grep -qx 'updater_action=none' <<<"$out" || fail "debian digest change must not rebuild the sidecar: $out"
pass "debian base moved → revision/none"

out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a2 sha256:c1)
grep -qx 'action=none' <<<"$out" || fail "alpine change must not rebuild the resolver: $out"
grep -qx 'updater_action=revision' <<<"$out" || fail "alpine digest change: $out"
pass "alpine base moved → none/revision"

out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a1 sha256:c2)
grep -qx 'updater_action=revision' <<<"$out" || fail "cosign digest change: $out"
pass "cosign image moved → none/revision"

out=$(decide 1.27.0 sha256:d2 sha256:s2 sha256:a2 sha256:c2)
[ "$out" = $'action=version\nupdater_action=revision' ] || fail "everything moved: $out"
pass "everything moved → version/revision"

# A state file predating the sidecar keys must count as "changed" once, so
# the first run after this change records them — but never as a resolver change.
printf '{ "debian": "sha256:d1", "distroless": "sha256:s1" }\n' > "$tmp/.build-state.json"
out=$(decide 1.26.0 sha256:d1 sha256:s1 sha256:a1 sha256:c1)
[ "$out" = $'action=none\nupdater_action=revision' ] || fail "legacy state without sidecar keys: $out"
pass "legacy .build-state.json → none/revision"

for v in "" "sha256:d1"; do
  if out=$(decide 1.26.0 "$v" "" sha256:a1 sha256:c1 2>&1); then fail "empty digest was accepted: $out"; fi
done
pass "an empty digest is a hard error, never a bump"

echo "ALL MONITOR TESTS PASSED"
```

Lancer : `bash tests/monitor.sh` → attendu `FAIL` (`decide-updates.sh: No such file`).

- [ ] **Step 2: `.github/scripts/decide-updates.sh`**

```bash
#!/usr/bin/env bash
# Decision logic of the update monitor (upstream-check.yml), kept out of the
# workflow so tests/monitor.sh can exercise it without GitHub.
#
# Inputs (environment): LATEST (newest upstream Unbound version), NEW_DEBIAN,
# NEW_DISTROLESS, NEW_ALPINE, NEW_COSIGN (freshly resolved digests).
# Files: versions.env, .build-state.json in the current directory.
# Output (stdout): action=version|revision|none  (resolver)
#                  updater_action=revision|none  (sidecar)
set -euo pipefail

for v in LATEST NEW_DEBIAN NEW_DISTROLESS NEW_ALPINE NEW_COSIGN; do
  # An empty digest would compare unequal to the stored one, trigger a
  # spurious release and then be written into .build-state.json, making every
  # later run bump again. Fail loudly instead.
  [ -n "${!v:-}" ] || { echo "::error::$v is empty" >&2; exit 1; }
done

# shellcheck disable=SC1091
. ./versions.env

read_state() { python3 -c "import json,sys;print(json.load(open('.build-state.json')).get(sys.argv[1],''))" "$1"; }
OLD_DEBIAN=$(read_state debian)
OLD_DISTROLESS=$(read_state distroless)
OLD_ALPINE=$(read_state alpine)
OLD_COSIGN=$(read_state cosign)

# Monotonicity guard: only ever move UP. The tags API is paginated and page 1
# is not ordered by version, so a transient hiccup could report an older
# release as "latest" — without this guard that would auto-publish a
# downgrade as :latest.
NEWEST=$(printf '%s\n%s\n' "$LATEST" "$UNBOUND_VERSION" | sort -V | tail -1)
if [ "$LATEST" != "$UNBOUND_VERSION" ] && [ "$NEWEST" = "$LATEST" ]; then
  action=version
elif [ "$NEW_DEBIAN" != "$OLD_DEBIAN" ] || [ "$NEW_DISTROLESS" != "$OLD_DISTROLESS" ]; then
  if [ "$LATEST" != "$UNBOUND_VERSION" ]; then
    echo "::warning::upstream reported $LATEST, which is not above the pinned $UNBOUND_VERSION — ignoring it and treating this as a revision rebuild" >&2
  fi
  action=revision
else
  action=none
fi

# The sidecar's bases are independent of the resolver's: an Alpine or cosign
# update rebuilds only the sidecar, never the resolver, and vice versa.
if [ "$NEW_ALPINE" != "$OLD_ALPINE" ] || [ "$NEW_COSIGN" != "$OLD_COSIGN" ]; then
  updater_action=revision
else
  updater_action=none
fi

printf 'action=%s\nupdater_action=%s\n' "$action" "$updater_action"
```

Rendre exécutable (`chmod +x`). Lancer `bash tests/monitor.sh` → attendu `ALL MONITOR TESTS PASSED`.

- [ ] **Step 3: `versions.env` et `.build-state.json`**

`versions.env` (garder les valeurs actuelles des trois premières clés) :

```
UNBOUND_VERSION=1.26.0
UNBOUND_SHA256=77458a7156e275c0b7b17fabcb357cb12445d95cfcb26fb9bb7d5ecba45e0b63
REVISION=3
UPDATER_VERSION=1.0.0
UPDATER_REVISION=0
```

`.build-state.json` (garder les deux digests existants) :

```json
{
  "debian": "sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1",
  "distroless": "sha256:d199d20fb09c898d8822ae5cbd5cf3c6d424e9b5e1fc2eb9a719a7752cd9d861",
  "alpine": "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
  "cosign": "sha256:ad281047f85c5e1fc6ffbc30c2b55be3b07b4032bef715a12122ce5829619aca"
}
```

Vérifier les deux nouveaux digests avant de les écrire :

```bash
docker buildx imagetools inspect alpine:3.24 --format '{{println .Manifest.Digest}}' | head -1
docker buildx imagetools inspect ghcr.io/sigstore/cosign/cosign:v2.6.5 --format '{{println .Manifest.Digest}}' | head -1
```

S'ils diffèrent de ceux ci-dessus, utiliser les valeurs résolues.

- [ ] **Step 4: `upstream-check.yml`**

Remplacer les étapes `Check base image digests`, `Decide action`, `Update pins for a new Unbound version` (uniquement la ligne `printf … > versions.env`), `Bump revision for dependency updates` et `Commit state, tag, and dispatch release` par :

```yaml
      - name: Check base image digests
        id: digests
        run: |
          # Registry reads are retried: Docker Hub, gcr.io and ghcr.io
          # occasionally rate-limit or hiccup, and a red run every time would
          # be noise.
          resolve() {
            for _ in 1 2 3; do
              D=$(docker buildx imagetools inspect "$1" --format '{{println .Manifest.Digest}}' 2>/dev/null | head -1)
              [ -n "$D" ] && { echo "$D"; return 0; }
              sleep 10
            done
            return 1
          }
          DEBIAN=$(resolve debian:trixie) || { echo "debian digest resolution failed"; exit 1; }
          DISTROLESS=$(resolve gcr.io/distroless/base-debian13:nonroot) || { echo "distroless digest resolution failed"; exit 1; }
          ALPINE=$(resolve alpine:3.24) || { echo "alpine digest resolution failed"; exit 1; }
          COSIGN=$(resolve ghcr.io/sigstore/cosign/cosign:v2.6.5) || { echo "cosign digest resolution failed"; exit 1; }
          {
            echo "debian=$DEBIAN"
            echo "distroless=$DISTROLESS"
            echo "alpine=$ALPINE"
            echo "cosign=$COSIGN"
          } >> "$GITHUB_OUTPUT"

      - name: Decide action
        id: decide
        env:
          LATEST: ${{ steps.upstream.outputs.latest }}
          NEW_DEBIAN: ${{ steps.digests.outputs.debian }}
          NEW_DISTROLESS: ${{ steps.digests.outputs.distroless }}
          NEW_ALPINE: ${{ steps.digests.outputs.alpine }}
          NEW_COSIGN: ${{ steps.digests.outputs.cosign }}
        run: |
          # The logic lives in a script so tests/monitor.sh can exercise it.
          bash .github/scripts/decide-updates.sh | tee -a "$GITHUB_OUTPUT"
```

Dans `Update pins for a new Unbound version`, remplacer la ligne `printf 'UNBOUND_VERSION=%s\nUNBOUND_SHA256=%s\nREVISION=0\n' "$LATEST" "$SHA" > versions.env` par :

```bash
          # In place, key by key: versions.env also carries the sidecar's own
          # version and revision, which a resolver bump must not touch.
          sed -i -e "s/^UNBOUND_VERSION=.*/UNBOUND_VERSION=$LATEST/" \
                 -e "s/^UNBOUND_SHA256=.*/UNBOUND_SHA256=$SHA/" \
                 -e "s/^REVISION=.*/REVISION=0/" versions.env
```

Puis :

```yaml
      - name: Bump revision for dependency updates
        if: steps.decide.outputs.action == 'revision'
        run: |
          NEWREV=$((REVISION + 1))
          sed -i "s/^REVISION=.*/REVISION=$NEWREV/" versions.env
          echo "REVISION=$NEWREV" >> "$GITHUB_ENV"

      - name: Bump the sidecar revision for base updates
        if: steps.decide.outputs.updater_action == 'revision'
        run: |
          NEWREV=$((UPDATER_REVISION + 1))
          sed -i "s/^UPDATER_REVISION=.*/UPDATER_REVISION=$NEWREV/" versions.env
          echo "UPDATER_REVISION=$NEWREV" >> "$GITHUB_ENV"

      - name: Commit state, tag, and dispatch releases
        if: steps.decide.outputs.action != 'none' || steps.decide.outputs.updater_action != 'none'
        env:
          GH_TOKEN: ${{ github.token }}
          ACTION: ${{ steps.decide.outputs.action }}
          UPDATER_ACTION: ${{ steps.decide.outputs.updater_action }}
          NEW_DEBIAN: ${{ steps.digests.outputs.debian }}
          NEW_DISTROLESS: ${{ steps.digests.outputs.distroless }}
          NEW_ALPINE: ${{ steps.digests.outputs.alpine }}
          NEW_COSIGN: ${{ steps.digests.outputs.cosign }}
        run: |
          # shellcheck disable=SC1091
          . ./versions.env
          printf '{\n  "debian": "%s",\n  "distroless": "%s",\n  "alpine": "%s",\n  "cosign": "%s"\n}\n' \
            "$NEW_DEBIAN" "$NEW_DISTROLESS" "$NEW_ALPINE" "$NEW_COSIGN" > .build-state.json
          TAGS=()
          [ "$ACTION" != none ] && TAGS+=("v${UNBOUND_VERSION}-r${REVISION}")
          [ "$UPDATER_ACTION" != none ] && TAGS+=("updater-v${UPDATER_VERSION}-r${UPDATER_REVISION}")
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add versions.env .build-state.json
          git commit -m "chore: ${TAGS[*]} (resolver: ${ACTION}, sidecar: ${UPDATER_ACTION}) [skip ci]"
          for t in "${TAGS[@]}"; do git tag "$t"; done
          # --atomic so a rejected main (someone else pushed first) cannot leave
          # a tag behind on the remote: a stranded tag would make every later
          # run fail with "already exists" until a human deletes it. Push only
          # these tags, never --tags.
          git push --atomic origin main "${TAGS[@]}"
          # A tag pushed with GITHUB_TOKEN does not trigger workflows, so each
          # release has to be dispatched explicitly against its tag. The push
          # already happened, so a failed dispatch would otherwise mean a silent,
          # permanent missed release (the next run sees none/none). Retry, then
          # fail the job so the miss is visible in the Actions UI.
          failed=""
          for t in "${TAGS[@]}"; do
            case "$t" in updater-v*) wf=updater.yml ;; *) wf=release.yml ;; esac
            ok=0
            for i in 1 2 3 4 5; do
              if gh workflow run "$wf" --ref "$t" -f tag="$t"; then ok=1; break; fi
              echo "dispatch of $wf for $t: attempt $i failed; retrying in 15s"
              sleep 15
            done
            [ "$ok" = 1 ] || failed="$failed $wf:$t"
          done
          if [ -n "$failed" ]; then
            echo "::error::release dispatch failed after 5 attempts for:$failed — run manually: gh workflow run <workflow> --ref <tag> -f tag=<tag>"
            exit 1
          fi
```

- [ ] **Step 5: `release.yml` — vérifier ce qu'on vient de signer**

Après l'étape `Sign images (keyless OIDC)` :

```yaml
      - name: Verify signatures (the published index must verify with the documented identity)
        env:
          DIGEST_HUB: ${{ steps.digest.outputs.hub }}
          DIGEST_GHCR: ${{ steps.digest.outputs.ghcr }}
          REPO: ${{ github.repository }}
        run: |
          for ref in "${DOCKERHUB_IMAGE}@${DIGEST_HUB}" "${GHCR_IMAGE}@${DIGEST_GHCR}"; do
            cosign verify "$ref" \
              --certificate-identity-regexp "https://github.com/${REPO}/.*" \
              --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null
          done
```

- [ ] **Step 6: `ci.yml`**

Dans le job `lint`, après l'étape hadolint existante, ajouter :

```yaml
      - name: hadolint (updater/Dockerfile)
        run: docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d < updater/Dockerfile

      - name: shellcheck (every shell source)
        run: |
          docker run --rm -v "$PWD:/mnt" -w /mnt \
            koalaman/shellcheck-alpine@sha256:c82fe42504fbc9fc68f15d36638e5ee2324ebb8b94e96a3c4e395bf361c49183 \
            shellcheck -S warning \
              tests/structure.sh tests/functional.sh tests/updater.sh tests/updater/lib.sh tests/monitor.sh \
              updater/unbound-autoupdate updater/entrypoint.sh updater/lib/*.sh updater/www/cgi-bin/metrics \
              .github/scripts/decide-updates.sh

      - name: Monitor decision logic
        run: bash tests/monitor.sh
```

(Le digest de `koalaman/shellcheck-alpine:stable` ci-dessus est celui résolu le 2026-09-16 ; vérifier avec `docker buildx imagetools inspect koalaman/shellcheck-alpine:stable --format '{{println .Manifest.Digest}}' | head -1`.)

Ajouter le job après `build-and-test` :

```yaml
  updater:
    runs-on: ubuntu-latest
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Load pinned versions
        run: cat versions.env >> "$GITHUB_ENV"

      - name: Load pinned base image digests
        run: |
          python3 - <<'PY' >> "$GITHUB_ENV"
          import json
          state = json.load(open('.build-state.json'))
          print(f"ALPINE_BASE=alpine:3.24@{state['alpine']}")
          print(f"COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5@{state['cosign']}")
          PY

      - name: Build the sidecar image
        run: |
          docker build -t unbound-autoupdate:test \
            --build-arg "ALPINE_BASE=$ALPINE_BASE" \
            --build-arg "COSIGN_IMAGE=$COSIGN_IMAGE" \
            --build-arg "UPDATER_VERSION=${UPDATER_VERSION}-r${UPDATER_REVISION}" \
            updater/

      # The suite drives real containers, real DNS, real cosign verification
      # against published images and a throwaway registry. It is the gate
      # that would have caught the tag-mismatch defect of the retired
      # host-side updater.
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

- [ ] **Step 7: `.github/workflows/updater.yml`**

```yaml
name: Updater release

on:
  push:
    tags: ['updater-v*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Release tag (e.g. updater-v1.0.0-r0)'
        required: true

permissions:
  contents: write
  packages: write
  id-token: write
  issues: write
  attestations: write

concurrency:
  group: updater-release
  cancel-in-progress: false

env:
  DOCKERHUB_IMAGE: esitcparis/unbound-autoupdate
  GHCR_IMAGE: ghcr.io/esitc-paris/unbound-autoupdate

# Same shape and guarantees as release.yml, different scope: every action is
# pinned to a full commit SHA; each architecture builds and runs the FULL
# integration suite natively on its own runner, then pushes by digest only;
# the merge job assembles the multi-arch manifest lists, signs them, verifies
# what it signed, and creates the GitHub Release.
jobs:
  prepare:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    outputs:
      tag: ${{ steps.tag.outputs.tag }}
      full: ${{ steps.tag.outputs.full }}
      rev: ${{ steps.tag.outputs.rev }}
      minor: ${{ steps.tag.outputs.minor }}
      major: ${{ steps.tag.outputs.major }}
    steps:
      - name: Resolve tag
        id: tag
        env:
          RAW_TAG: ${{ github.event.inputs.tag || github.ref_name }}
        run: |
          TAG="$RAW_TAG"
          if [[ ! "$TAG" =~ ^updater-v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$ ]]; then
            echo "bad tag format: $TAG (expected updater-vX.Y.Z-rN)"
            exit 1
          fi
          # updater-v1.0.0-r2 -> full=1.0.0 rev=2 minor=1.0 major=1
          FULL="${TAG#updater-v}"; FULL="${FULL%-r*}"
          REV="${TAG##*-r}"
          MINOR="${FULL%.*}"
          MAJOR="${FULL%%.*}"
          {
            echo "tag=$TAG"
            echo "full=$FULL"
            echo "rev=$REV"
            echo "minor=$MINOR"
            echo "major=$MAJOR"
          } >> "$GITHUB_OUTPUT"

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ steps.tag.outputs.tag }}

      - name: Cross-check tag against versions.env
        env:
          TAG_NAME: ${{ steps.tag.outputs.tag }}
          TAG_FULL: ${{ steps.tag.outputs.full }}
          TAG_REV: ${{ steps.tag.outputs.rev }}
        run: |
          # shellcheck disable=SC1091
          . ./versions.env
          [ "$UPDATER_VERSION" = "$TAG_FULL" ] \
            || { echo "tag $TAG_NAME does not match versions.env (UPDATER_VERSION=$UPDATER_VERSION)"; exit 1; }
          [ "$UPDATER_REVISION" = "$TAG_REV" ] \
            || { echo "tag $TAG_NAME revision r$TAG_REV does not match versions.env (UPDATER_REVISION=$UPDATER_REVISION)"; exit 1; }

  build:
    needs: prepare
    strategy:
      fail-fast: true
      matrix:
        include:
          - platform: linux/amd64
            runner: ubuntu-latest
          - platform: linux/arm64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ needs.prepare.outputs.tag }}

      - name: Load pinned versions
        run: cat versions.env >> "$GITHUB_ENV"

      - name: Load pinned base image digests
        run: |
          python3 - <<'PY' >> "$GITHUB_ENV"
          import json
          state = json.load(open('.build-state.json'))
          print(f"ALPINE_BASE=alpine:3.24@{state['alpine']}")
          print(f"COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5@{state['cosign']}")
          PY

      - name: Sanitize platform name
        env:
          PLATFORM: ${{ matrix.platform }}
        run: echo "PLATFORM_PAIR=${PLATFORM//\//-}" >> "$GITHUB_ENV"

      - uses: docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e # v4.3.0

      - name: Build image for testing (native)
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          context: updater
          load: true
          platforms: ${{ matrix.platform }}
          tags: unbound-autoupdate:test
          build-args: |
            ALPINE_BASE=${{ env.ALPINE_BASE }}
            COSIGN_IMAGE=${{ env.COSIGN_IMAGE }}
            UPDATER_VERSION=${{ env.UPDATER_VERSION }}-r${{ env.UPDATER_REVISION }}
          cache-from: type=gha,scope=updater-${{ env.PLATFORM_PAIR }}
          cache-to: type=gha,mode=max,scope=updater-${{ env.PLATFORM_PAIR }}

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

      - name: Login to Docker Hub
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Login to GHCR
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push platform image by digest (untagged) with SBOM + provenance
        id: push
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          context: updater
          platforms: ${{ matrix.platform }}
          sbom: true
          provenance: mode=max
          build-args: |
            ALPINE_BASE=${{ env.ALPINE_BASE }}
            COSIGN_IMAGE=${{ env.COSIGN_IMAGE }}
            UPDATER_VERSION=${{ env.UPDATER_VERSION }}-r${{ env.UPDATER_REVISION }}
          outputs: type=image,"name=${{ env.DOCKERHUB_IMAGE }},${{ env.GHCR_IMAGE }}",push-by-digest=true,name-canonical=true,push=true
          cache-from: type=gha,scope=updater-${{ env.PLATFORM_PAIR }}

      - name: Export digest
        env:
          DIGEST: ${{ steps.push.outputs.digest }}
        run: |
          mkdir -p /tmp/digests
          touch "/tmp/digests/${DIGEST#sha256:}"

      - name: Upload digest
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: updater-digests-${{ env.PLATFORM_PAIR }}
          path: /tmp/digests/*
          if-no-files-found: error
          retention-days: 1

  merge:
    needs: [prepare, build]
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - name: Download digests
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          path: /tmp/digests
          pattern: updater-digests-*
          merge-multiple: true

      - uses: docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e # v4.3.0

      - name: Login to Docker Hub
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Login to GHCR
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Create multi-arch manifest lists
        env:
          TAG_MAJOR: ${{ needs.prepare.outputs.major }}
          TAG_MINOR: ${{ needs.prepare.outputs.minor }}
          TAG_FULL: ${{ needs.prepare.outputs.full }}
          TAG_REV: ${{ needs.prepare.outputs.rev }}
        run: |
          cd /tmp/digests
          COUNT=$(find . -maxdepth 1 -type f | wc -l)
          [ "$COUNT" -eq 2 ] || { echo "expected 2 platform digests, found $COUNT"; exit 1; }
          REFS_HUB=""; REFS_GHCR=""
          for f in *; do
            REFS_HUB="$REFS_HUB $DOCKERHUB_IMAGE@sha256:$f"
            REFS_GHCR="$REFS_GHCR $GHCR_IMAGE@sha256:$f"
          done
          # shellcheck disable=SC2086
          docker buildx imagetools create \
            -t "$DOCKERHUB_IMAGE:latest" \
            -t "$DOCKERHUB_IMAGE:$TAG_MAJOR" \
            -t "$DOCKERHUB_IMAGE:$TAG_MINOR" \
            -t "$DOCKERHUB_IMAGE:$TAG_FULL" \
            -t "$DOCKERHUB_IMAGE:$TAG_FULL-r$TAG_REV" \
            $REFS_HUB
          # shellcheck disable=SC2086
          docker buildx imagetools create \
            -t "$GHCR_IMAGE:latest" \
            -t "$GHCR_IMAGE:$TAG_MAJOR" \
            -t "$GHCR_IMAGE:$TAG_MINOR" \
            -t "$GHCR_IMAGE:$TAG_FULL" \
            -t "$GHCR_IMAGE:$TAG_FULL-r$TAG_REV" \
            $REFS_GHCR

      - name: Resolve index digests
        id: digest
        env:
          TAG_FULL: ${{ needs.prepare.outputs.full }}
          TAG_REV: ${{ needs.prepare.outputs.rev }}
        run: |
          HUB=$(docker buildx imagetools inspect "$DOCKERHUB_IMAGE:$TAG_FULL-r$TAG_REV" --format '{{println .Manifest.Digest}}' | head -1)
          GHCR=$(docker buildx imagetools inspect "$GHCR_IMAGE:$TAG_FULL-r$TAG_REV" --format '{{println .Manifest.Digest}}' | head -1)
          [ -n "$HUB" ] && [ -n "$GHCR" ] || { echo "index digest resolution failed"; exit 1; }
          {
            echo "hub=$HUB"
            echo "ghcr=$GHCR"
          } >> "$GITHUB_OUTPUT"

      - name: Install cosign
        uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
        with:
          # Pinned to the cosign v2 CLI, the version the sidecar image itself
          # embeds and verifies with (updater/Dockerfile). Moving to v3 is a
          # conscious change made together with release.yml and the image.
          cosign-release: v2.6.5

      - name: Sign images (keyless OIDC)
        env:
          DIGEST_HUB: ${{ steps.digest.outputs.hub }}
          DIGEST_GHCR: ${{ steps.digest.outputs.ghcr }}
        run: |
          cosign sign --yes "${DOCKERHUB_IMAGE}@${DIGEST_HUB}"
          cosign sign --yes "${GHCR_IMAGE}@${DIGEST_GHCR}"

      - name: Verify signatures (the published index must verify with the documented identity)
        env:
          DIGEST_HUB: ${{ steps.digest.outputs.hub }}
          DIGEST_GHCR: ${{ steps.digest.outputs.ghcr }}
          REPO: ${{ github.repository }}
        run: |
          for ref in "${DOCKERHUB_IMAGE}@${DIGEST_HUB}" "${GHCR_IMAGE}@${DIGEST_GHCR}"; do
            cosign verify "$ref" \
              --certificate-identity-regexp "https://github.com/${REPO}/.*" \
              --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null
          done

      - name: GitHub provenance attestation (Docker Hub image)
        uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
        with:
          subject-name: index.docker.io/${{ env.DOCKERHUB_IMAGE }}
          subject-digest: ${{ steps.digest.outputs.hub }}

      - name: GitHub provenance attestation (GHCR image)
        uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
        with:
          subject-name: ${{ env.GHCR_IMAGE }}
          subject-digest: ${{ steps.digest.outputs.ghcr }}

      - name: Create GitHub Release
        uses: softprops/action-gh-release@3d0d9888cb7fd7b750713d6e236d1fcb99157228 # v3.0.2
        with:
          tag_name: ${{ needs.prepare.outputs.tag }}
          generate_release_notes: true
          body: |
            **unbound-autoupdate ${{ needs.prepare.outputs.full }}** (revision r${{ needs.prepare.outputs.rev }}) — multi-arch (amd64, arm64), Alpine, signed.

            **Images:**
            - `${{ env.DOCKERHUB_IMAGE }}:${{ needs.prepare.outputs.full }}-r${{ needs.prepare.outputs.rev }}`
            - `${{ env.GHCR_IMAGE }}:${{ needs.prepare.outputs.full }}-r${{ needs.prepare.outputs.rev }}`

            **Digests:** Docker Hub `${{ steps.digest.outputs.hub }}` · GHCR `${{ steps.digest.outputs.ghcr }}`

            Verify:
            ```
            cosign verify ${{ env.DOCKERHUB_IMAGE }}@${{ steps.digest.outputs.hub }} \
              --certificate-identity-regexp 'https://github.com/${{ github.repository }}/.*' \
              --certificate-oidc-issuer https://token.actions.githubusercontent.com
            ```

      - name: Notify admin (release published)
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.prepare.outputs.tag }}
          DIGEST_HUB: ${{ steps.digest.outputs.hub }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          gh issue create \
            --title "Published $TAG" \
            --assignee euca01 \
            --body "$(printf 'Sidecar release %s was published automatically.\n\nImage: %s:%s\nDigest: %s\nRun: %s\n\nThis is a notification issue — close it after reading.' \
              "$TAG" "$DOCKERHUB_IMAGE" "${TAG#updater-v}" "$DIGEST_HUB" "$RUN_URL")"

  notify-failure:
    needs: [prepare, build, merge]
    if: failure()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Notify admin (release failed)
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          RAW_TAG: ${{ needs.prepare.outputs.tag || github.ref_name }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          TITLE="Updater release pipeline failed for $RAW_TAG"
          NUM=$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --json number,title \
            -q ".[] | select(.title==\"$TITLE\") | .number" | head -1)
          if [ -n "$NUM" ]; then
            gh issue comment "$NUM" --repo "$GITHUB_REPOSITORY" --body "Failed again: $RUN_URL"
          else
            gh issue create --repo "$GITHUB_REPOSITORY" --title "$TITLE" --assignee euca01 \
              --body "$(printf 'The updater release pipeline failed — nothing was published.\n\nInvestigate: %s' "$RUN_URL")"
          fi
```

`softprops/action-gh-release` ne trouvera pas de « previous tag » du même préfixe la première fois ; `generate_release_notes` s'en accommode.

- [ ] **Step 8: Valider**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
bash tests/monitor.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning .github/scripts/decide-updates.sh tests/monitor.sh
# The CI build command must work locally with the pinned digests:
. ./versions.env
ALPINE_BASE="alpine:3.24@$(python3 -c "import json;print(json.load(open('.build-state.json'))['alpine'])")"
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v2.6.5@$(python3 -c "import json;print(json.load(open('.build-state.json'))['cosign'])")"
docker build -t unbound-autoupdate:test --build-arg "ALPINE_BASE=$ALPINE_BASE" --build-arg "COSIGN_IMAGE=$COSIGN_IMAGE" --build-arg "UPDATER_VERSION=${UPDATER_VERSION}-r${UPDATER_REVISION}" updater/
docker run --rm --entrypoint cat unbound-autoupdate:test /usr/local/lib/unbound-autoupdate/VERSION   # → 1.0.0-r0
```

Attendu : actionlint silencieux, `ALL MONITOR TESTS PASSED`, image construite, VERSION `1.0.0-r0`.

- [ ] **Step 9: Commit**

```bash
git add versions.env .build-state.json .github/scripts/decide-updates.sh .github/workflows tests/monitor.sh
git commit -m "ci: sidecar release workflow, monitor tracks Alpine and cosign digests, shellcheck and integration gates, post-sign verification"
```

---

### Task 7: Documentation, extrait compose, règles d'alerte

**Files:**
- Create: `updater/README.md`, `updater/compose.snippet.yml`, `docs/observability/prometheus.yml`, `docs/observability/alerts.yml`
- Modify: `README.md`, `docs/trust.md`, `docker-compose.yml`, `.github/workflows/ci.yml` (lint : `promtool check rules`), `updater/.dockerignore`
- Test: `promtool check rules`, `docker compose config` sur l'exemple, grep des sections obligatoires

**Interfaces:** aucune nouvelle.

- [ ] **Step 1: Les vérifications, qui échouent**

```bash
docker run --rm -v "$PWD/docs/observability:/obs:ro" --entrypoint promtool prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996 check rules /obs/alerts.yml
for s in 'Docker socket' 'Install' 'same absolute path' 'check' 'SELF_UPDATE' 'METRICS_PORT' 'COSIGN_PUBLIC_KEY' 'NOTIFY_HOST' 'REQUIRE_DNSSEC' 'Metrics' 'does not do'; do grep -q "$s" updater/README.md || echo "missing: $s"; done
```

Attendu : `alerts.yml` introuvable, sections manquantes.

- [ ] **Step 2: `updater/compose.snippet.yml`**

```yaml
# Drop these two services into the same docker-compose.yml as your resolver.
# Replace /opt/unbound with YOUR project directory: the same absolute path
# must appear on both sides of the bind mount, because Compose resolves
# relative bind mounts against the project directory and the Docker daemon
# then applies them on the host.
#
# The Docker socket is root on the host. No container updater can do
# without it; see updater/README.md before enabling this.
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

- [ ] **Step 3: `docs/observability/prometheus.yml` et `alerts.yml`**

`prometheus.yml` :

```yaml
# Scrape configuration excerpt for unbound-distroless hosts. The sidecar's
# metrics service exposes both the resolver's statistics (unbound_*) and the
# updater's own state (unbound_autoupdate_*) on one endpoint.
scrape_configs:
  - job_name: unbound
    scrape_interval: 30s
    static_configs:
      - targets: ['resolver-1.example:9167', 'resolver-2.example:9167']

rule_files:
  - alerts.yml
```

`alerts.yml` :

```yaml
groups:
  - name: unbound
    rules:
      - alert: UnboundDown
        expr: up{job="unbound"} == 0 or unbound_exporter_scrape_success == 0
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "Unbound on {{ $labels.instance }} is not answering unbound-control"
          description: "The metrics sidecar cannot collect statistics from the resolver container for 2 minutes."
      - alert: UnboundServfailRatioHigh
        expr: |
          rate(unbound_answer_rcodes_total{rcode="SERVFAIL"}[5m])
            / rate(unbound_total_num_queries[5m]) > 0.05
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "More than 5% SERVFAIL on {{ $labels.instance }}"
          description: "Upstream reachability or DNSSEC failures; check `log-servfail` lines in the resolver logs."
      - alert: UnboundNoDnssecValidation
        expr: |
          increase(unbound_answers_secure_total[1h]) == 0
            and increase(unbound_total_num_queries[1h]) > 100
        for: 1h
        labels: {severity: warning}
        annotations:
          summary: "No DNSSEC-secure answers in the last hour on {{ $labels.instance }}"
          description: "Queries are flowing but nothing validates: the validator may be disabled or the trust anchor broken."

  - name: unbound-autoupdate
    rules:
      - alert: UnboundAutoupdateStale
        expr: time() - unbound_autoupdate_last_cycle_timestamp_seconds > 3 * 3600
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "No update cycle for over 3 hours on {{ $labels.instance }}"
          description: "With INTERVAL=1h the sidecar should have run three cycles. Is the unbound-autoupdate container running?"
      - alert: UnboundAutoupdateFailed
        expr: unbound_autoupdate_last_cycle_status{status=~"blocked|error"} == 1
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "Last update cycle failed ({{ $labels.status }}) on {{ $labels.instance }}"
          description: "Signature, preflight, canary or an unexpected error stopped the last cycle. Production was not touched. See the sidecar logs."
      - alert: UnboundAutoupdateRolledBack
        expr: increase(unbound_autoupdate_cycles_total{status="rollback"}[1h]) > 0
        labels: {severity: warning}
        annotations:
          summary: "An update was rolled back on {{ $labels.instance }}"
          description: "The new image or configuration failed post-swap validation; production was restored and the change quarantined."
      - alert: UnboundAutoupdateCritical
        expr: unbound_autoupdate_last_cycle_status{status="critical"} == 1
        labels: {severity: critical}
        annotations:
          summary: "Rollback FAILED on {{ $labels.instance }} — DNS may be down"
          description: "The swap failed and the rollback did not restore a working resolver. Manual intervention required."
      - alert: UnboundAutoupdateQuarantine
        expr: unbound_autoupdate_quarantine_active == 1
        for: 25h
        labels: {severity: warning}
        annotations:
          summary: "A {{ $labels.axis }} change is still quarantined on {{ $labels.instance }}"
          description: "RETRY_AFTER has elapsed and the quarantined change will be retried; decide whether it should be."
```

- [ ] **Step 4: `updater/README.md`**

Sections, dans cet ordre, chacune un titre `##` :

1. **What it does** — le cycle en huit puces (discover, compare image and configuration, quarantine, major guard + cosign, preflight, canary on cloned state, swap, post-swap gate + rollback), puis une phrase : *the new image is validated with **your** configuration and a clone of **your** state before anything is deployed.*
2. **The Docker socket is root on the host** — en tête, avant l'installation : aucun updater de conteneurs ne peut s'en passer ; ce que le sidecar fait avec (pull, run canary, compose up on one service, exec unbound-control) ; option `docker-socket-proxy` et ses limites (le self-update et `compose up` exigent `POST`, `CONTAINERS`, `IMAGES`, `NETWORKS`, `VOLUMES`, `EXEC`, ce qui rend le proxy peu restrictif).
3. **Install** — l'extrait compose (copie de `compose.snippet.yml`), puis `docker compose up -d`, puis `docker compose logs -f unbound-autoupdate` avec la ligne `baseline recorded` attendue.
4. **The same-absolute-path rule** — pourquoi, et le message exact : `compose file '/opt/unbound/docker-compose.yml' is not readable from inside the sidecar — mount the project directory read-only at the SAME absolute path`.
5. **Validate without deploying** — `docker compose run --rm unbound-autoupdate check`.
6. **Variables** — table : `INTERVAL` (1h), `SPLAY` (10%), `RUN_MODE` (loop), `WATCH_CONFIG` (1), `HC_URL`, `WEBHOOK_URL`, `NOTIFY_HOST` (daemon host name), `ALLOW_MAJOR` (0), `SELF_UPDATE` (1), `STRICT_BOGUS_CHECK` (0), `REQUIRE_DNSSEC` (1), `RETRY_AFTER` (24h), `TARGET_SERVICE` (auto), `VALIDATE_DOMAIN` (example.com), `COSIGN_IDENTITY_REGEXP`, `COSIGN_ISSUER`, `COSIGN_PUBLIC_KEY` (unset = keyless), `COSIGN_IGNORE_TLOG` (0), `METRICS_PORT` (9167).
7. **Behaviour** — table : nothing new · unsigned image · canary rejected · swap OK · swap failed → rollback · rollback failed · major bump · quarantined image/config · sidecar self-update OK · sidecar self-update failed. Colonnes : Exit code, Healthchecks, Notification event, Metric status.
8. **Metrics and alerts** — `/metrics` sur 9167, ce qu'il contient (unbound_* depuis `stats_noreset`, `unbound_autoupdate_*`), renvoi à `docs/observability/`, un exemple de ligne de chaque famille.
9. **Self-update** — actif par défaut ; vérifié par cosign ; appliqué par un conteneur éphémère lancé depuis la nouvelle image ; rollback et quarantaine `self` ; `SELF_UPDATE=0` pour désactiver.
10. **Verifying with your own key** — `COSIGN_PUBLIC_KEY` monté en lecture seule, `COSIGN_IGNORE_TLOG=1` pour un miroir hors Rekor.
11. **What it does not do** — Kubernetes, containers outside Compose, `network_mode: host` (the canary cannot join an isolated network from a host-networked sidecar; the cycle refuses up front), Grafana dashboards.

Toute affirmation de ce README doit correspondre à un comportement du code ou d'un test ; en cas de doute, lire le code, pas la spec.

Dans `updater/.dockerignore`, garder `README.md` et `compose.snippet.yml`.

- [ ] **Step 5: README racine, `docs/trust.md`, `docker-compose.yml`**

`README.md` : après la section « Images and tags », ajouter :

```markdown
## Automatic updates

A companion sidecar keeps a Compose-managed resolver current: it verifies the
new image's signature, runs it as a canary with **your** configuration and a
clone of **your** state, swaps only if the canary validates, checks the swap
actually happened, and rolls back if production fails. It also exposes
`/metrics` for Prometheus. See **[updater/README.md](updater/README.md)** —
it needs the Docker socket, which is root on the host, so read that first.
```

`docs/trust.md` : après « Verifying releases », ajouter une section « The updater sidecar » qui décrit : image `esitcparis/unbound-autoupdate` / `ghcr.io/esitc-paris/unbound-autoupdate`, tags `X.Y.Z-rN` (revision bumped when Alpine or the cosign image moves), même pipeline (native amd64/arm64, full integration suite per arch, Trivy, push by digest, keyless signature **verified after signing**, SBOM, provenance), commande `cosign verify esitcparis/unbound-autoupdate:latest …` identique à celle du résolveur, et le fait que le sidecar vérifie lui-même chaque image du résolveur et de lui-même avant de l'exécuter. Dans « Automatic updates », préciser que le moniteur surveille aussi les bases du sidecar.

`docker-compose.yml` : ajouter, en commentaire, les deux services de `compose.snippet.yml` après le service `unbound`, précédés de :

```yaml
  # ── Automatic updates + Prometheus metrics (optional) ──────────────────────
  # Uncomment both services and replace /opt/unbound with this project's
  # absolute directory. Read updater/README.md first: the Docker socket is
  # root on the host.
```

- [ ] **Step 6: CI — `promtool check rules`**

Dans `ci.yml`, job `lint`, après l'étape « Monitor decision logic » :

```yaml
      - name: promtool (alert rules)
        run: |
          docker run --rm -v "$PWD/docs/observability:/obs:ro" --entrypoint promtool \
            prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996 \
            check rules /obs/alerts.yml
```

- [ ] **Step 7: Vérifier**

```bash
docker run --rm -v "$PWD/docs/observability:/obs:ro" --entrypoint promtool prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996 check rules /obs/alerts.yml
for s in 'Docker socket' 'Install' 'same absolute path' 'check' 'SELF_UPDATE' 'METRICS_PORT' 'COSIGN_PUBLIC_KEY' 'NOTIFY_HOST' 'REQUIRE_DNSSEC' 'Metrics' 'does not do'; do grep -q "$s" updater/README.md || echo "missing: $s"; done
# The example compose file must still be valid with the services uncommented:
sed 's/^  # \(  \)/  \1/; s/^  # \([a-z]\)/  \1/' docker-compose.yml > /tmp/compose-check.yml   # adapt to how the block was commented
docker compose -f /tmp/compose-check.yml config >/dev/null
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
grep -rn 'updater/VERSION\|deploy/unbound-autoupdate' --include='*.md' --include='*.yml' . | grep -v 'docs/superpowers\|deploy/README.md' || echo "no dangling references"
```

Attendu : `SUCCESS` de promtool, aucune section manquante, `compose config` silencieux, actionlint silencieux, aucune référence pendante.

- [ ] **Step 8: Commit**

```bash
git add updater/README.md updater/compose.snippet.yml updater/.dockerignore docs/observability README.md docs/trust.md docker-compose.yml .github/workflows/ci.yml
git commit -m "docs(updater): user guide, compose snippet, Prometheus scrape config and alert rules"
```

---

### Task 8: Suite complète et vérification finale

**Files:** aucun nouveau.

- [ ] **Step 1: Tout reconstruire et tout lancer**

```bash
docker build -t unbound-autoupdate:test updater/
bash tests/updater.sh unbound-autoupdate:test 2>&1 | tee /tmp/updater-final.log
bash tests/monitor.sh
bash tests/structure.sh esitcparis/unbound-distroless:1
bash tests/functional.sh esitcparis/unbound-distroless:1
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable shellcheck -S warning tests/*.sh tests/updater/lib.sh updater/unbound-autoupdate updater/entrypoint.sh updater/lib/*.sh updater/www/cgi-bin/metrics .github/scripts/decide-updates.sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d < updater/Dockerfile
```

Attendu : `ALL UPDATER TESTS PASSED` avec 34 PASS, `ALL MONITOR TESTS PASSED`, structure et fonctionnel verts, linters silencieux, `docker ps -a | grep -E 'canary|upd-|registry'` vide.

- [ ] **Step 2: Arrêt propre du service compose complet**

```bash
mkdir -p /tmp/upd-smoke && cp unbound.conf /tmp/upd-smoke/ && cd /tmp/upd-smoke
# write a docker-compose.yml with the resolver + both sidecar services from updater/compose.snippet.yml,
# image: unbound-autoupdate:test for both, /tmp/upd-smoke as the project dir
docker compose up -d && sleep 8 && docker compose logs unbound-autoupdate | grep -E 'starting|baseline recorded'
curl -fsS http://127.0.0.1:9167/metrics | grep -c '^unbound_'
time docker compose down -v      # < 5 s
cd - && rm -rf /tmp/upd-smoke
```

- [ ] **Step 3: Rien à committer**

`git status --short` doit être vide.

## Auto-relecture

**Couverture de la spec**

| Section | Tâche |
|---|---|
| §3 modes et boucle, SPLAY absolu ou %, SIGTERM | 4a |
| §4 verify.sh, mode clé, sortie cosign sur stderr | 2 |
| §5 self-update, helper, rollback, quarantaine `self`, refus = blocked/1 | 5 (hook et statuts : 3) |
| §6.1 service metrics, httpd, proxy `/metrics`, CGI, 200 dégradé | 4b |
| §6.2 conversion, HELP/TYPE, histogramme | 3 |
| §6.3 metrics.prom, statuts, compteurs, quarantaines par axe | 3 (helper : 5) |
| §6.4 règles d'alerte, scrape config | 7 |
| §7.1 versions, VERSION généré, tags updater-vX.Y.Z-rN | 4a, 6 |
| §7.2 digests dans .build-state.json, build-args | 4a, 6 |
| §7.3 moniteur, deux décisions, deux tags, deux dispatches | 6 |
| §7.4 updater.yml, cosign verify post-signature, ci.yml shellcheck + job updater | 6 |
| §8 tests | 2, 3, 4a, 4b, 5, 6 (`tests/monitor.sh` en plus) |
| §9 documentation | 7 |
| découverte sans confondre le service metrics | 1 |

**Cohérence des noms** — `discover_target_container`, `SELF_IMAGE_ID`, `_image_repo` (Task 1) ; `verify_image`, `COSIGN_PUBLIC_KEY`, `COSIGN_IGNORE_TLOG` (2) ; `state_inc`, `self_quarantine_*`, `_quarantine_window_open`, `SELF_ROLLBACK_FILE`, `record_cycle`, `write_cycle_metrics`, `stats_to_prometheus`, `METRICS_FILE`, `CYCLE_STATUSES`, `finish` (3) ; `exec_metrics_server`, `METRICS_PORT` (4) ; `self_update`, `self_update_apply`, `SELF_UPDATE_LAUNCHED`, label `unbound-autoupdate.helper=1` (5) ; `FIXTURE_UPDATER_IMAGE`, `registry_forward`, `cosign_test_keys`, `TEST_PUBKEY`, `registry_sign`, `promtool_check`, `fixture_service_image_id` (tests). Tous utilisés sous ces noms exacts.

**Nombre de tests attendu** — 23 existants + `t0_stats_to_prometheus_unit`, `t0_cycle_metrics_unit`, `t_verify_key_accepts_signed`, `t_modes` (3 pass), `t_loop_sigterm`, `t_metrics_scrape` (2 pass), `t_self_update_applies`, `t_self_update_rolls_back` = 34 lignes PASS.
