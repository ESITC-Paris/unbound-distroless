# Sidecar de mise à jour automatique — design

Date : 2026-09-06 · Statut : validé, prêt pour la planification d'implémentation

## 1. Contexte

`unbound-distroless` publie déjà ses images de façon entièrement automatique :
`upstream-check.yml` détecte une nouvelle version d'Unbound ou un changement de
digest des bases, tague, et `release.yml` construit nativement sur amd64 et
arm64, passe `tests/structure.sh`, `tests/functional.sh` et Trivy sur chaque
architecture, puis publie une image signée par cosign avec SBOM et provenance.

Ce pipeline teste l'image **de manière générique**, avec la configuration par
défaut du dépôt. Il ne peut pas tester la configuration de chaque utilisateur.

Côté consommation, `deploy/unbound-autoupdate` (script hôte + timer systemd)
était censé combler ce manque. Il est **inopérant**.

## 2. Le défaut de l'existant

Le script tire et valide le tag `:1` (`IMAGE:TAG` en dur), mais effectue le
swap par `docker compose up -d`, qui déploie le tag écrit dans le fichier
compose — `:latest` dans le `docker-compose.yml` et le README du dépôt.

Tirer `:1` ne modifie pas le pointeur local de `:latest`, et Compose ne
re-tire pas par défaut (`pull_policy: missing`). Conséquence :

1. le canari valide correctement la nouvelle image ;
2. `compose up -d` ne change rien — le conteneur reste sur l'ancienne image ;
3. les gates post-swap passent (l'ancien conteneur est parfaitement sain) ;
4. le script journalise « production updated », envoie un mail de succès et
   ping Healthchecks ;
5. le cycle recommence à l'identique à chaque heure, indéfiniment.

L'utilisateur est notifié d'un succès et n'est jamais mis à jour. C'est le
pire mode de défaillance possible pour un updater : silencieux et rassurant.

Défauts secondaires relevés dans le même script :

| # | Point |
|---|---|
| 1 | `docker image prune -f` : prune global de l'hôte, non borné aux objets créés par l'updater |
| 2 | Gate post-swap câblé sur `127.0.0.1:53` → rollback abusif si le résolveur publie sur une IP LAN |
| 3 | Aucun `unbound-checkconf` : une conf invalide ne remonte qu'en « never became healthy » + 15 lignes de log |
| 4 | Une conf custom qui bascule `remote-control` en TCP/TLS casse le `HEALTHCHECK` de l'image → le canari rejette toute mise à jour à vie, sans diagnostic |
| 5 | Le canari est joint par IP de bridge Docker, non routable sous Docker Desktop |
| 6 | `install.sh` refuse tout conteneur non Compose ; `cosign` tiré de `releases/latest` (non épinglé, v3 alors que la release signe en v2) ; installation par `curl \| sh` depuis `main` mutable — incohérent avec la discipline d'épinglage du projet |
| 7 | Pas de mode « test seul » : impossible de valider sa conf sans risquer un swap |
| 8 | `busybox` tiré de Docker Hub pour cloner le volume : une image non vérifiée dans une chaîne de confiance par ailleurs stricte |

Constat vérifié en séance : `unbound.conf.local` (conf de référence du site)
ne passe pas `unbound-checkconf` contre l'image publiée — elle déclare un
`remote-control` en TCP/TLS dont les fichiers clé et certificat n'existent pas
dans l'image, et que `structure.sh` interdit délibérément d'y inclure.

## 3. Objectif

Livrer aux utilisateurs de l'image une solution de mise à jour automatique
qui, avant tout déploiement réel, **valide la nouvelle image avec la
configuration locale de l'utilisateur et l'état réel de son résolveur**.

### Non-objectifs

- Kubernetes. Cible : `docker compose` uniquement.
- Mise à jour de conteneurs lancés hors Compose (`docker run` nu).
- Remplacement du pipeline de publication, qui reste inchangé.

## 4. Décisions

| Décision | Choix | Raison |
|---|---|---|
| Forme | Conteneur sidecar | Déclaré dans le même `docker-compose.yml` que le résolveur ; pas de dépendance à systemd ; installation en trois montages |
| Cible | `docker compose` | Seul cas documenté et testé |
| Architecture | Compose-natif | Le swap passe par `compose pull` + `compose up -d`, donc on déploie exactement ce que Compose déclare : le désaccord de tag devient structurellement impossible |
| Déclencheur | Image **et** configuration | Éditer sa conf déclenche un canari puis un rechargement, ce qui est littéralement « on teste la conf locale, si c'est bon on déploie » |
| Publication | Semver propre, tags `updater-vX.Y.Z`, workflow dédié | Cycle de vie indépendant d'Unbound ; pas de collision avec le regex `v*` de `release.yml` |
| `deploy/` | Supprimé, stub explicatif | Le script est inopérant ; le stub énonce le défaut et redirige |

## 5. Architecture

### 5.1 Découverte — rien n'est configuré à la main

Le sidecar résout d'abord sa propre identité de conteneur (via
`/proc/self/mountinfo`, repli sur `$HOSTNAME`), puis lit ses propres labels
Compose pour connaître son projet. Le service cible est le service frère du
même projet dont le nom de dépôt d'image contient `unbound`. Ce critère est
volontairement lâche pour rester valable sur un fork ou un miroir privé. Si
la découverte ne trouve pas exactement un candidat — zéro comme plusieurs —
`TARGET_SERVICE` devient obligatoire, et le sidecar s'arrête en nommant les
candidats trouvés plutôt qu'en devinant.

Du conteneur cible, il lit :

```
com.docker.compose.project                → -p du projet
com.docker.compose.project.config_files   → -f des fichiers compose
com.docker.compose.project.working_dir    → --project-directory
.Mounts                                   → volume d'état + confs bind-montées
.Image                                    → digest réellement en service
```

### 5.2 Contrainte de chemin

Compose résout les bind-mounts relatifs (`./unbound.conf`) contre le
répertoire projet, puis demande au démon — qui vit sur l'hôte — de les
monter. Le répertoire projet doit donc être visible du sidecar **au même
chemin absolu que sur l'hôte**, en lecture seule.

C'est incontournable : Compose a besoin de ses fichiers pour reconstruire le
projet. Si un fichier de conf bind-monté se trouve hors du répertoire projet
et n'est donc pas lisible par le sidecar, la découverte échoue avec un
message qui nomme le fichier manquant, plutôt que de calculer une empreinte
partielle silencieusement fausse.

### 5.3 Cycle

```
 1. État désiré     compose pull --quiet <service> → digest de l'image déclarée
                    sha256 de chaque fichier de conf bind-monté
 2. État courant    digest réel du conteneur en marche (source de vérité :
                    un changement manuel est détecté, pas seulement les nôtres)
 3. Inchangé ?      → ping Healthchecks, retour en veille
 4. Quarantaine ?   → si ce digest a déjà échoué et que RETRY_AFTER n'est pas
                      écoulé, on ne retente pas ; notification récapitulative
 5. Majeure ?       → refus sauf ALLOW_MAJOR=1, avec notification
 6. Signature       cosign verify du nouveau digest
                    (sauté si seule la conf a changé)
 7. Pré-vol         unbound-checkconf, sur la NOUVELLE image, avec LA conf
 8. Canari          clone du volume d'état + conf réelle, réseau isolé
 9. Validation      sonde de disponibilité puis UDP / TCP / drapeau AD
10. Swap            compose up -d --no-deps <service>
11. Post-swap       mêmes critères, contre le conteneur de prod
12. Échec           rollback, quarantaine du digest, alerte
13. Succès          état enregistré, notification, ping
```

L'image est tirée (étape 1) avant d'être vérifiée (étape 6) : tirer n'est pas
exécuter, et le digest est justement ce que la vérification doit constater.
Rien de non vérifié ne démarre jamais.

Si le conteneur en service a été construit localement et n'expose donc aucun
`RepoDigests`, la comparaison de l'étape 2 est impossible : le sidecar
s'arrête avec un message explicite au lieu de considérer l'écart comme une
mise à jour à déployer.

La détection de version majeure (étape 5) compare le label
`org.opencontainers.image.version` de l'image en service et de la nouvelle,
et non le tag déclaré — un utilisateur qui suit `:latest` n'a aucun numéro
majeur dans son fichier compose.

Les étapes 9 et 11 appellent **la même fonction** : ce qui a été jugé bon sur
le canari est exactement ce qui est exigé de la production.

`--no-deps` est obligatoire à l'étape 10 : sans lui, `compose up` recréerait
aussi le sidecar, qui se tuerait au milieu de son propre cycle.

### 5.4 Canari

- Réseau bridge isolé, créé et détruit par le cycle.
- Volume d'état cloné depuis celui de la production, avec **l'image du
  sidecar elle-même** — signée par le même pipeline — au lieu de `busybox`.
- Conf de l'utilisateur montée exactement comme en production.
- Le sidecar se raccorde temporairement au réseau du canari
  (`docker network connect`), interroge le canari par son IP, puis se
  déconnecte. Aucun port publié, aucune dépendance à la routabilité du
  bridge depuis l'hôte.
- La production n'est pas touchée : elle continue de servir pendant tout le
  canari.

Le clone d'un volume vivant peut théoriquement produire une copie non
atomique de `root.key`. Le risque est faible (écritures rares) et documenté
plutôt que masqué.

### 5.5 Validation

Sonde de disponibilité **maison**, par requête DNS répétée jusqu'à réponse ou
délai dépassé. Le `HEALTHCHECK` de l'image devient indicatif et non bloquant :
il dépend de la socket de contrôle unix, que la conf d'un utilisateur peut
légitimement remplacer par un `remote-control` TCP/TLS.

Critères, identiques canari et post-swap :

1. résolution UDP → `NOERROR` avec au moins une réponse ;
2. résolution TCP → `NOERROR` ;
3. `. SOA +dnssec` → drapeau `ad` présent (la validation DNSSEC fonctionne) ;
4. optionnel (`STRICT_BOGUS_CHECK=1`) : `dnssec-failed.org` → `SERVFAIL`.

Chaque requête est retentée : un résolveur froid peut transitoirement
échouer pendant son amorçage.

### 5.6 Rollback et quarantaine

Le rollback écrit un fichier d'override dans le volume d'état du sidecar,
épinglant `image: <repo>@sha256:<digest précédent>` — celui relevé sur le
conteneur en service à l'étape 2, et non une valeur mémorisée d'un cycle
antérieur — puis rejoue
`compose up -d --no-deps` avec les deux fichiers. Déterministe, et sans
mutation d'un tag local — contrairement au `docker tag` de l'existant.

Le digest fautif est ensuite mis en **quarantaine** dans l'état persistant.
Sans cela, le cycle suivant reverrait le même écart et retenterait le même
canari indéfiniment, à chaque intervalle.

La quarantaine se lève quand le digest déclaré change à nouveau, ou après
`RETRY_AFTER` (24 h par défaut).

La notification d'échec doit énoncer explicitement que le conteneur tourne
sur le digest précédent alors que le fichier compose déclare toujours le
nouveau tag : un `docker compose up -d` lancé à la main par l'utilisateur
redéploierait l'image fautive.

## 6. Interface utilisateur

```yaml
  unbound-autoupdate:
    image: esitcparis/unbound-autoupdate:1
    restart: unless-stopped
    environment:
      INTERVAL: 1h
      HC_URL: https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/unbound:/opt/unbound:ro
      - autoupdate-state:/var/lib/unbound-autoupdate

volumes:
  autoupdate-state:
```

Le chemin absolu littéral est recommandé plutôt que `${PWD}`, qui n'est pas
défini quand Compose est invoqué depuis une unité systemd.

### Variables

| Variable | Défaut | Rôle |
|---|---|---|
| `INTERVAL` | `1h` | Période du cycle. Suffixes `s`, `m`, `h`, `d` |
| `SPLAY` | `10%` | Dispersion aléatoire, pour ne pas synchroniser une flotte |
| `RUN_MODE` | `loop` | `loop`, `once` ou `check`. Un argument passé à l'entrypoint prime sur cette variable |
| `WATCH_CONFIG` | `1` | Déclencher aussi sur changement d'empreinte de conf |
| `HC_URL` | — | Healthchecks : `/start`, succès, `/fail` |
| `WEBHOOK_URL` | — | POST JSON générique |
| `ALLOW_MAJOR` | `0` | Autoriser le franchissement de version majeure |
| `SELF_UPDATE` | `0` | Le sidecar se met à jour lui-même, en dernière instruction |
| `STRICT_BOGUS_CHECK` | `0` | Exiger `SERVFAIL` sur `dnssec-failed.org` |
| `RETRY_AFTER` | `24h` | Levée de quarantaine d'un digest fautif |
| `TARGET_SERVICE` | auto | Obligatoire si la découverte est ambiguë |
| `VALIDATE_DOMAIN` | `example.com` | Domaine de la sonde de résolution |
| `COSIGN_IDENTITY_REGEXP` | dépôt amont | À surcharger pour un fork |
| `COSIGN_ISSUER` | GitHub Actions OIDC | — |

### Mode test seul

```bash
docker compose run --rm unbound-autoupdate check
```

Exécute tout le cycle jusqu'à la validation du canari, affiche le verdict,
et **ne fait jamais de swap**. C'est le « on teste la config locale pour
s'assurer que tout est opérationnel » disponible à la demande, sans
attendre le prochain intervalle.

## 7. Sécurité

**Le socket Docker vaut root sur l'hôte.** Aucun updater de conteneurs ne
peut s'en passer. Le README l'énonce en clair, en tête de la section
d'installation, et documente l'option socket-proxy pour qui veut réduire la
surface — plutôt que d'enfouir le compromis.

**Le gate cosign reste fail-closed.** Une image dont la signature ne remonte
pas au workflow de release de ce dépôt n'est jamais déployée, quelle que
soit sa provenance : un registre compromis ne suffit pas.

**Portée des actions.** Le sidecar ne touche qu'aux objets qu'il a créés
(réseau et volume de canari) et au seul service découvert. Aucun `prune`
global.

**Auto-mise à jour désactivée par défaut.** Si `SELF_UPDATE=1`, le
`compose up -d` du service updater est la toute dernière instruction du
cycle, après persistance de l'état : le conteneur meurt en se remplaçant, et
non au milieu d'un swap.

## 8. Image du sidecar

Base Alpine épinglée par digest. Le distroless n'est pas tenable : il faut un
shell, le CLI Docker et le plugin Compose. Ce choix est documenté plutôt que
contourné.

Contenu : `docker-cli`, `docker-cli-compose`, `bind-tools`, `curl`, et
**cosign copié depuis l'image officielle épinglée par digest en v2.6.5** — la
version exacte avec laquelle `release.yml` signe.

Mêmes exigences que le résolveur : multi-arch amd64 + arm64 construit
nativement, scan Trivy bloquant, signature cosign keyless, SBOM et
provenance.

## 9. Tests

Le défaut fatal de l'existant aurait été attrapé par un seul test. La suite
`tests/updater.sh` s'exécute contre un vrai démon Docker en CI.

| | Scénario | Ce qu'il verrouille |
|---|---|---|
| T1 | Image ancienne en service, tag mobile déclaré → un cycle | Le conteneur tourne réellement sur le nouveau digest. **Régression du bug de tag** |
| T2 | Second cycle sans changement | Aucune recréation, aucun faux « updated » |
| T3 | Édition du fichier de conf monté | Le déclencheur configuration fonctionne |
| T4 | Conf syntaxiquement invalide | Refus en pré-vol ; conteneur de prod intact (même ID) |
| T5 | Conf qui casse le `HEALTHCHECK` (`remote-control` TCP sans certs) | Erreur `checkconf` précise, pas un timeout opaque |
| T6 | Image locale non signée présentée comme l'image déclarée | Le gate cosign refuse ; prod intacte |
| T7 | Canari vert, post-swap rouge | Rollback vers le digest précédent, résolveur sain, digest en quarantaine |
| T8 | Franchissement de version majeure | Refus sans `ALLOW_MAJOR` |

T7 provoque un échec authentique (conf appliquée entre canari et swap qui
échoue au démarrage réel) plutôt qu'une injection de faute artificielle : un
test qui ne vérifie que son propre mock ne vérifie rien.

Ajout transverse : **shellcheck** sur tout le shell du dépôt. La CI ne lint
aujourd'hui que les workflows et le Dockerfile.

## 10. Impact sur le dépôt

```
updater/Dockerfile
updater/unbound-autoupdate            moteur
updater/entrypoint                    boucle d'ordonnancement
updater/README.md
updater/compose.snippet.yml
updater/VERSION
tests/updater.sh
.github/workflows/ci.yml              + job shellcheck, + job d'intégration updater
.github/workflows/updater.yml         build / test / sign / publish sur updater-v*
docker-compose.yml                    service updater, commenté
README.md                             section « Mises à jour automatiques »
docs/trust.md                         mise à jour du chapitre auto-update
docs/operations.md                    pointeur
deploy/                               supprimé, remplacé par un stub explicatif
```

## 11. Prérequis de lancement

Actions hors dépôt, à faire par le mainteneur :

1. Créer le dépôt Docker Hub `esitcparis/unbound-autoupdate` (le GHCR se crée
   tout seul à la première poussée).
2. Vérifier que `DOCKERHUB_TOKEN` a les droits d'écriture sur ce nouveau dépôt.

## 12. Hors périmètre

- `unbound.conf.local` ne passe pas `checkconf` (voir §2). Réparable
  séparément : `remote-control` vers la socket unix, et rétablissement de
  l'`auth-zone "."` absente, qui fait perdre la racine hyperlocale RFC 8806
  dès que cette conf est montée.
- Suivi du digest de la base Alpine du sidecar par `upstream-check.yml`,
  écarté pour l'instant : le workflow `updater.yml` peut être rejoué à la
  demande, et Trivy garde le portail.
