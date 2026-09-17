# Sidecar de mise à jour : finition, observabilité et chaîne de confiance — design

Date : 2026-09-16 · Statut : validé, prêt pour la planification d'implémentation
Prolonge : `2026-09-06-sidecar-autoupdate-design.md` (cycle, canari, rollback, quarantaine)

## 1. Point de départ

Tout ce qui suit est constaté dans le code de la branche `feat/autoupdate-sidecar`
au commit `c164415`, pas dans la documentation.

- `updater/unbound-autoupdate` et ses cinq bibliothèques réalisent le cycle
  complet et passent 23 tests d'intégration.
- `updater/entrypoint.sh` fait `sleep infinity` : l'image publiée telle quelle
  ne lancerait aucun cycle.
- Aucun workflow ne construit, teste, signe ni publie l'image du sidecar ;
  `ci.yml` n'exécute ni shellcheck ni `tests/updater.sh`.
- `updater/Dockerfile` fige en dur les digests d'`alpine:3.22` et de
  `cosign:v2.6.5`. `upstream-check.yml` ne surveille que Debian et distroless :
  une mise à jour de sécurité Alpine ne déclenche aucune reconstruction.
- Le résolveur n'expose ses statistiques que par `unbound-control` via
  `docker exec`. Le sidecar n'émet que des lignes logfmt, un webhook JSON et
  des pings Healthchecks.
- `SELF_UPDATE`, prévu par la spec précédente, n'existe pas.
- La vérification cosign n'accepte qu'une identité OIDC.

## 2. Objectif

Rendre le sidecar déployable, supervisable et maintenu automatiquement, avec la
même discipline que le résolveur : tout est testé, signé, épinglé et reconstruit
sans intervention humaine quand une base bouge.

### Décisions prises avec le mainteneur

| Décision | Choix |
|---|---|
| Base du sidecar | Alpine **3.24**, épinglée par digest |
| Supervision | Prometheus : exporteur et règles d'alerte |
| Exporteur Unbound | Intégré au sidecar, aucune image supplémentaire |
| Self-update | Implémenté, **actif par défaut** |
| Assemblage | Une image, deux services compose, un processus par conteneur |

### Non-objectifs

Kubernetes ; conteneurs lancés hors Compose ; canari en `network_mode: host`
(limitation acceptée : le démon refuse de raccorder un conteneur en réseau hôte
à un autre réseau, `canary_up` le dit et s'arrête) ; tableau de bord Grafana ;
base Debian pour le sidecar ; compose de production durci du résolveur.

## 3. Modes et boucle

`updater/entrypoint.sh` remplace le placeholder. Il source `log.sh` et
`state.sh`, puis dispatche sur `MODE="${1:-${RUN_MODE:-loop}}"` :

| Mode | Comportement |
|---|---|
| `loop` | Un cycle, puis attente `INTERVAL` (défaut `1h`) plus une dispersion aléatoire de `SPLAY` (défaut `10%`), indéfiniment. Un cycle en échec est journalisé et n'arrête pas la boucle. |
| `once` | `exec` d'un cycle ; le code de sortie du cycle est celui du conteneur. |
| `check` | Comme `once` avec `CHECK_ONLY=1` : tout est validé jusqu'au canari, rien n'est swappé. |
| `metrics` | Sert `/metrics` (§6). Ne lance jamais de cycle. |
| `self-update-apply` | Usage interne du conteneur éphémère de self-update (§5). |

L'attente est un `sleep` en arrière-plan sous `wait`, pour que le SIGTERM
transmis par tini interrompe le sommeil : un `docker compose down` prend moins
de trois secondes, testé.

`SPLAY` accepte un pourcentage (`10%`) ou une durée absolue (`5m`) ; une
valeur invalide arrête le conteneur avec un message explicite.

## 4. Vérification de signature : OIDC ou clé

`updater/lib/verify.sh` (nouveau) expose `verify_image <ref>` et remplace
l'appel direct à `cosign verify` de l'orchestrateur :

- si `COSIGN_PUBLIC_KEY` est défini, chemin d'un fichier PEM :
  `cosign verify --key "$COSIGN_PUBLIC_KEY" <ref>` ;
- sinon, l'identité keyless actuelle : `--certificate-identity-regexp` et
  `--certificate-oidc-issuer`.

Les deux modes sont exclusifs et fail-closed. La sortie de cosign est
conservée et écrite sur stderr en cas d'échec : un opérateur doit voir *pourquoi*
une signature est refusée, pas seulement qu'elle l'est. Le mode clé sert aux
miroirs privés qui re-signent, et il rend le self-update testable sans
contourner la barrière (§8).

## 5. Self-update

`SELF_UPDATE` vaut `1` par défaut. Le self-update ne s'exécute qu'à la fin
d'un cycle terminé en « à jour » ou « mis à jour et vérifié », jamais après un
échec, un saut délibéré ni en mode `check`.

### 5.1 Détection et garde

1. Le service propre du sidecar est le label `com.docker.compose.service` de
   `SELF_ID`. Les services à recréer sont tous ceux du projet dont `image`,
   dans `compose config`, est identique à celui du service propre : en
   pratique `unbound-autoupdate` et `unbound-metrics`.
2. `compose pull --quiet <service propre>` puis comparaison du digest déclaré
   au digest en service de `SELF_ID`. Identiques : rien à faire.
3. Garde de version majeure sur le label `org.opencontainers.image.version`,
   soumis à `ALLOW_MAJOR` comme pour le résolveur.
4. `verify_image` sur le nouveau digest. Refus : notification `blocked`,
   `hc_fail`, statut `blocked` et sortie `1`, même si le résolveur, lui, est
   à jour : une image de sidecar non signée dans le registre est un incident
   de chaîne d'approvisionnement, pas un détail. La quarantaine `self` n'est
   pas posée dans ce cas ; le refus se répète à chaque cycle tant que l'image
   déclarée n'est pas signée, ce qui est le comportement voulu.

### 5.2 Application par conteneur éphémère

Un `compose up -d` lancé depuis le conteneur qu'il remplace meurt quand Compose
arrête ce conteneur, avant d'avoir démarré le nouveau. L'application se fait
donc depuis l'extérieur :

```
docker run -d --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v <projet>:<projet>:ro  -v <volume d'état>:/var/lib/unbound-autoupdate \
  -e WEBHOOK_URL -e HC_URL -e NOTIFY_HOST -e COSIGN_* \
  <nouveau digest> self-update-apply <projet> <workdir> <fichiers -f…> <ancien digest> <services…>
```

Le conteneur éphémère tourne sur la **nouvelle** image, déjà vérifiée. Il :

1. exécute `compose up -d --no-deps <services…>` ;
2. attend jusqu'à 30 s que le nouveau conteneur du service propre soit
   `running` **et** ait écrit sa ligne de démarrage dans ses logs ;
3. sinon, écrit un override épinglant `<ancien digest>` pour ces services,
   rejoue `compose up -d --no-deps`, et notifie `critical` ; le digest fautif
   est mis en quarantaine dans l'état, sur un troisième axe `SELF`, avec le
   même `RETRY_AFTER` ;
4. en succès, notifie `updated` avec l'ancienne et la nouvelle version, met à
   jour `metrics.prom`, et sort.

L'orchestrateur, lui, sort `0` immédiatement après avoir lancé le conteneur
éphémère : sa propre mort fait partie du plan. Le cycle suivant, exécuté par le
nouveau sidecar, retrouve un état cohérent parce que l'état vit dans le volume.

L'override de self-update est un fichier distinct de `rollback.yml`
(`self-rollback.yml`), et `_compose_file_args` l'exclut au même titre.

## 6. Métriques

### 6.1 Service `metrics`

Même image, second conteneur, `RUN_MODE: metrics`. Il lance `httpd` de
`busybox-extras` en avant-plan sur le port `METRICS_PORT` (défaut `9167`, le
port conventionnel d'`unbound_exporter`), racine
`/usr/local/lib/unbound-autoupdate/www`, avec une règle de proxy
`P:/metrics:http://127.0.0.1:<port>/cgi-bin/metrics` pour que le chemin
public soit `/metrics`. Vérifié sur Alpine 3.24 : `httpd` est bien dans
`busybox-extras`, la règle de proxy fonctionne.

Le script CGI `cgi-bin/metrics` :

1. découvre le conteneur du résolveur par les labels Compose (projet du
   sidecar, service `TARGET_SERVICE` ou unique candidat dont l'image contient
   `unbound`), sans `compose config` : `discover.sh` est scindé en
   `discover_target_container` (labels seuls) et `discover_target` (complet) ;
2. exécute `docker exec <cible> /usr/local/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset` ;
3. convertit chaque ligne `clé=valeur` (§6.2) ;
4. concatène `$STATE_DIR/metrics.prom` s'il existe (§6.3) ;
5. ajoute `unbound_exporter_scrape_success` (1/0) et
   `unbound_exporter_scrape_duration_seconds`.

Un échec de l'exec ne casse pas le scrape : la réponse contient
`unbound_exporter_scrape_success 0` et les métriques du sidecar, avec HTTP 200.
Le volume d'état est monté en lecture seule dans ce conteneur.

### 6.2 Conversion des statistiques Unbound

Chaque métrique a des lignes `# HELP` et `# TYPE` : `promtool check metrics`
retourne un code non nul sans elles, et le test l'exige.

| Clé `stats_noreset` | Métrique |
|---|---|
| `total.num.<x>` | `unbound_<x>_total` (counter) : `unbound_queries_total`, `unbound_cachehits_total`, `unbound_recursivereplies_total`, … |
| autre `total.<x>` (`requestlist.*`, `tcpusage`) | `unbound_<x>` (gauge), points remplacés par `_` |
| `thread<N>.num.<x>` | `unbound_thread_<x>_total{thread="N"}` (counter) |
| autre `thread<N>.<x>` | `unbound_thread_<x>{thread="N"}` (gauge) |
| `num.query.type.<T>` | `unbound_query_types_total{type="T"}` |
| `num.query.class.<C>` | `unbound_query_classes_total{class="C"}` |
| `num.query.opcode.<O>` | `unbound_query_opcodes_total{opcode="O"}` |
| `num.answer.rcode.<R>` | `unbound_answer_rcodes_total{rcode="R"}` |
| `num.query.flags.<F>` | `unbound_query_flags_total{flag="F"}` |
| `num.query.aggressive.<R>` | `unbound_query_aggressive_total{rcode="R"}` |
| `num.answer.secure`, `num.answer.bogus`, `num.rrset.bogus` | `unbound_answers_secure_total`, `unbound_answers_bogus_total`, `unbound_rrset_bogus_total` |
| `histogram.<lo>.to.<hi>` | seaux cumulés de `unbound_response_time_seconds` (histogram), `_sum` depuis `total.recursion.time.avg × total.num.recursivereplies`, `_count` = somme des seaux |
| `total.recursion.time.avg`, `.median` | `unbound_recursion_time_seconds{stat="avg"\|"median"}` (gauge) |
| `time.up`, `time.now`, `time.elapsed` | `unbound_time_up_seconds`, … (gauge) |
| `mem.*` | `unbound_mem_<x>_bytes` (gauge) |
| `msg.cache.count`, `rrset.cache.count`, `infra.cache.count`, `key.cache.count` | `unbound_cache_entries{cache="…"}` (gauge) |
| `unwanted.queries`, `unwanted.replies` | `unbound_unwanted_queries_total`, `unbound_unwanted_replies_total` |
| toute autre clé | `unbound_stat{name="<clé>"}` (gauge), pour ne rien perdre |

Les noms suivent les conventions que `promtool check metrics` (promlint) impose,
et le test le vérifie avec le parseur de référence : un compteur porte le
suffixe `_total`, une jauge ne porte ni `_count` ni label `quantile`. Ces
noms ne sont donc pas ceux d'`unbound_exporter`, ce que la spec n'a jamais
promis.

Les compteurs sont cumulatifs parce que la configuration livrée déclare
`statistics-cumulative: yes` et que le script appelle `stats_noreset`. Si une
configuration utilisateur remet les compteurs à zéro, Prometheus voit des
resets et les fonctions `rate`/`increase` les tolèrent.

### 6.3 Métriques du sidecar

L'orchestrateur écrit `$STATE_DIR/metrics.prom` de façon atomique à la fin de
chaque cycle, quelle qu'en soit l'issue, et le conteneur éphémère de
self-update fait de même :

| Métrique | Type | Contenu |
|---|---|---|
| `unbound_autoupdate_info{version,image_digest}` | gauge = 1 | Version du sidecar, digest de sa propre image |
| `unbound_autoupdate_last_cycle_timestamp_seconds` | gauge | Fin du dernier cycle |
| `unbound_autoupdate_last_cycle_duration_seconds` | gauge | Durée du dernier cycle |
| `unbound_autoupdate_last_cycle_status{status}` | gauge one-hot | `up_to_date`, `updated`, `check_ok`, `skipped`, `blocked`, `rollback`, `critical`, `error` |
| `unbound_autoupdate_cycles_total{status}` | counter | Cumul persisté dans `state.env` (`CYCLES_<STATUS>`) |
| `unbound_autoupdate_quarantine_active{axis}` | gauge | `image`, `config`, `self` : 1 si une quarantaine est en cours |
| `unbound_autoupdate_target_image_info{digest,version}` | gauge = 1 | Ce que le résolveur exécute au dernier cycle |
| `unbound_autoupdate_self_update_last_timestamp_seconds` | gauge | Dernier self-update appliqué, 0 sinon |

Les statuts correspondent aux points de sortie existants de l'orchestrateur ;
chaque `exit` passe par une fonction `finish <status>` qui écrit le fichier,
incrémente le compteur, puis sort avec le code attendu (`0`, `1`, `2`).

### 6.4 Règles d'alerte de référence

`docs/observability/prometheus.yml` (extrait de scrape) et
`docs/observability/alerts.yml` :

| Alerte | Condition |
|---|---|
| `UnboundDown` | `up{job="unbound"} == 0` ou `unbound_exporter_scrape_success == 0` pendant 2 min |
| `UnboundServfailRatioHigh` | `rate(unbound_answer_rcodes_total{rcode="SERVFAIL"}[5m]) / rate(unbound_total_num_queries[5m]) > 0.05` pendant 10 min |
| `UnboundNoDnssecValidation` | `increase(unbound_answers_secure_total[1h]) == 0` alors que des requêtes arrivent |
| `UnboundAutoupdateStale` | `time() - unbound_autoupdate_last_cycle_timestamp_seconds > 3 × INTERVAL` |
| `UnboundAutoupdateFailed` | `unbound_autoupdate_last_cycle_status{status=~"blocked\|error"} == 1` |
| `UnboundAutoupdateRolledBack` | `increase(unbound_autoupdate_cycles_total{status="rollback"}[1h]) > 0` |
| `UnboundAutoupdateCritical` | `unbound_autoupdate_last_cycle_status{status="critical"} == 1` |
| `UnboundAutoupdateQuarantine` | `unbound_autoupdate_quarantine_active == 1` pendant 25 h |

## 7. Versions, digests, moniteur, workflows

### 7.1 Versions

`versions.env` devient :

```
UNBOUND_VERSION=…
UNBOUND_SHA256=…
REVISION=…
UPDATER_VERSION=1.0.0
UPDATER_REVISION=0
```

`updater/VERSION` disparaît : le Dockerfile reçoit `UPDATER_VERSION` en
build-arg (`1.0.0-r0`) et l'écrit à la fois dans le label OCI et dans
`/usr/local/lib/unbound-autoupdate/VERSION`. Un build local sans build-arg
produit `dev`.

Tag git du sidecar : `updater-vX.Y.Z-rN`. `X.Y.Z` change à la main quand le
code du sidecar change ; `rN` est incrémenté par le moniteur quand une base
bouge. Tags d'image : `X.Y.Z-rN` (immuable), `X.Y.Z`, `X.Y`, `X`, `latest`,
sur `esitcparis/unbound-autoupdate` et `ghcr.io/esitc-paris/unbound-autoupdate`.
Le regex `v*` de `release.yml` ne matche pas `updater-v…` ; celui
d'`updater.yml` est `^updater-v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$`.

### 7.2 Digests

`.build-state.json` :

```json
{ "debian": "sha256:…", "distroless": "sha256:…",
  "alpine": "sha256:…", "cosign": "sha256:…" }
```

`updater/Dockerfile` : `ARG ALPINE_BASE=alpine:3.24` et
`ARG COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5`, sans digest en dur ;
CI et `updater.yml` passent `alpine:3.24@<digest>` et `cosign:v2.6.5@<digest>`
depuis `.build-state.json`, exactement comme `DEBIAN_BASE` et `DISTROLESS_BASE`.

### 7.3 Moniteur

`upstream-check.yml` résout aussi `alpine:3.24` et
`ghcr.io/sigstore/cosign/cosign:v2.6.5`. La décision devient deux décisions
indépendantes :

- résolveur : inchangé (`version` / `revision` / `none`) ;
- sidecar : `revision` si le digest Alpine ou cosign a changé, sinon `none`.

Le commit unique met à jour `versions.env` et `.build-state.json` ; jusqu'à deux
tags sont créés et poussés dans le même `git push --atomic origin main <tags…>` ;
chaque tag est dispatché vers son workflow avec la même boucle de cinq
tentatives. Le passage à une nouvelle version de cosign reste manuel car
`release.yml` doit changer en même temps.

### 7.4 Workflows

`updater.yml`, calqué sur `release.yml` :

- `prepare` : validation du tag, croisement avec `UPDATER_VERSION` et
  `UPDATER_REVISION` ;
- `build` : matrice `linux/amd64` sur `ubuntu-latest` et `linux/arm64` sur
  `ubuntu-24.04-arm`, sans QEMU ; chaque architecture construit, exécute
  `bash tests/updater.sh` en entier, passe Trivy, pousse par digest avec SBOM
  et provenance ;
- `merge` : manifest lists sur les deux registres, `cosign sign` keyless,
  **`cosign verify` de l'index signé avec l'identité documentée**, attestations,
  Release GitHub, issue de notification ;
- `notify-failure` : une issue par tag cassé.

`release.yml` gagne la même étape `cosign verify` après la signature.

`ci.yml` : le job `lint` gagne shellcheck (image `koalaman/shellcheck-alpine`
épinglée par digest) sur tout le shell du dépôt ; un job `updater` construit
l'image avec les digests de `.build-state.json`, lance `tests/updater.sh` et
Trivy.

Contraintes reprises : actions épinglées au SHA, aucun `${{ }}` dans un corps
`run:`, images tierces épinglées par digest, `concurrency` par workflow.

## 8. Tests

Ajouts à `tests/updater.sh`, tous contre un démon Docker réel :

| Test | Ce qu'il verrouille |
|---|---|
| `t_modes` | `check` valide sans swapper ; `once` déploie ; `metrics` ne lance aucun cycle |
| `t_loop_sigterm` | un conteneur `loop` s'arrête en moins de 3 s sur `docker stop` |
| `t_metrics_scrape` | `/metrics` répond ; `promtool check metrics` rend 0 ; présence de `unbound_total_num_queries`, du histogramme, et des métriques `unbound_autoupdate_*` après un cycle ; `scrape_success 0` mais HTTP 200 quand le résolveur est arrêté |
| `t_verify_key_accepts_signed` | une image du registre jetable signée par la clé de test passe la barrière avec `COSIGN_PUBLIC_KEY` ; la même image non signée est refusée |
| `t_self_update_applies` | le sidecar, déclaré sur une image du registre jetable, se met à jour vers une image re-signée ; les deux services tournent sur le nouveau digest ; `metrics.prom` le reflète |
| `t_self_update_rolls_back` | une nouvelle image dont l'entrypoint sort immédiatement est appliquée puis annulée par le conteneur éphémère ; les services tournent sur l'ancien digest ; quarantaine `self` active ; notification `critical` |
| `t_state_metrics_unit` | `finish` écrit un `metrics.prom` complet et incrémente les compteurs ; validé par `promtool` |

Les images du registre jetable sont signées avec une paire de clés générée par
`cosign generate-key-pair` dans le répertoire de test ; le mot de passe est
vide et la clé n'est jamais commitée. `promtool` vient de `prom/prometheus`
épinglé par digest. Les tests existants restent inchangés.

La suite complète tourne dans `ci.yml` et dans `updater.yml` sur les deux
architectures.

## 9. Documentation et fichiers

```
updater/entrypoint.sh                 remplacé
updater/lib/verify.sh                 nouveau
updater/lib/metrics.sh                nouveau : conversion stats → Prometheus, écriture de metrics.prom
updater/lib/selfupdate.sh             nouveau
updater/www/httpd.conf                nouveau
updater/www/cgi-bin/metrics           nouveau
updater/Dockerfile                    alpine:3.24, busybox-extras, build-args, VERSION généré
updater/VERSION                       supprimé
updater/README.md                     nouveau
updater/compose.snippet.yml           nouveau, deux services
versions.env, .build-state.json       clés sidecar
.github/workflows/updater.yml         nouveau
.github/workflows/ci.yml              shellcheck + job updater
.github/workflows/release.yml         cosign verify post-signature
.github/workflows/upstream-check.yml  digests Alpine et cosign, second tag
docs/observability/prometheus.yml     nouveau
docs/observability/alerts.yml         nouveau
docs/trust.md                         chaîne du sidecar
docker-compose.yml                    deux services en commentaire
README.md                             section « Automatic updates » renvoyant à updater/
tests/updater.sh, tests/updater/lib.sh tests §8, signature par clé, promtool
```

`updater/README.md` contient, dans l'ordre : ce que fait le sidecar ; le
socket Docker vaut root sur l'hôte, en tête ; installation avec l'extrait
compose ; la contrainte de chemin identique avec le message d'erreur exact ;
tester sans déployer ; table des variables, y compris `SELF_UPDATE`,
`METRICS_PORT`, `COSIGN_PUBLIC_KEY`, `NOTIFY_HOST`, `REQUIRE_DNSSEC` ; table
des comportements par issue ; métriques et alertes ; ce que le sidecar ne fait
pas.

## 10. Prérequis de lancement, hors dépôt

1. Créer le dépôt Docker Hub `esitcparis/unbound-autoupdate`.
2. Vérifier que `DOCKERHUB_TOKEN` peut y écrire.
3. Après le premier `updater-v1.0.0-r0`, rendre le paquet GHCR public.
