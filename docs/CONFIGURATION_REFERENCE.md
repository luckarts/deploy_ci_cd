# Configuration & Debug Reference — Infra bachelart.fr

Document de référence pour ne rien oublier de la configuration actuelle,
et pour déboguer méthodiquement en cas d'erreur future. Complète
`MIGRATION_RUNBOOK.md` (qui couvrait la migration ponctuelle) — celui-ci
est un aide-mémoire durable.

---

## 1. Architecture — qui possède quoi

Le principe : **ce repo (`deploy_ci_cd`) est l'orchestrateur d'infra
partagée uniquement.** Il ne contient aucune app.

```
deploy_ci_cd/              (github.com/luckarts/deploy_ci_cd, branche master)
├── traefik/                → reverse proxy, un seul pour tous les projets
├── monitoring/             → prometheus, loki, grafana, promtail, cadvisor,
│                              alertmanager, crowdsec
├── registry/               → registre Docker privé (registry.bachelart.fr)
├── compose.watchtower.yml  → auto-redéploiement (surveille TOUS les
│                              containers labelisés, tous projets confondus)
└── scripts/deploy.sh       → networks|traefik|monitoring|registry|watchtower|all

my-app/deploy/              (github.com/luckarts/portfolio_particule)
├── compose.yml             → nextjs + database (portfolio)
└── .env.prod / .env.staging

poker_training/deploy/      → garde son propre compose.yml + .env, pareil
```

Chaque app garde son `.env` — jamais de `.env` partagé entre deux stacks.

**Réseaux partagés** (créés une fois par `deploy.sh networks`, `external:
true` dans tous les compose qui les référencent) :
- `traefik-web` — tout ce qui doit être routable par Traefik
- `monitoring-network` — tout ce que prometheus/promtail/cadvisor doivent
  pouvoir scraper par nom DNS (logs et métriques CPU/RAM passent par
  `docker.sock`/cgroups, host-wide, **indépendamment** de ce réseau — voir
  §3)

⚠️ **Piège rencontré** : avant la migration, deux stacks séparées créaient
chacune un réseau nommé `monitoring-network`, mais Docker les namespace
par projet (`monitoring_monitoring-network` vs
`poker-training-staging_monitoring-network`) — donc deux réseaux
*différents* malgré le même nom. Grafana ne pouvait pas résoudre
`prometheus`/`loki` par DNS. D'où la règle : un seul projet crée
`monitoring-network` (`external: true` partout ailleurs).

---

## 2. Ce qui est déjà automatique (ne pas re-câbler)

- **Logs** : `promtail` lit `/var/run/docker.sock` → voit les logs de
  **tous** les containers du host, quel que soit leur réseau Docker.
- **CPU/RAM/disque par container** : `cadvisor` lit les cgroups/`/sys`
  directement → pareil, host-wide, aucune dépendance réseau.
- Donc attacher un container à `monitoring-network` n'est utile QUE si
  Prometheus doit le **scraper** par nom DNS (un endpoint `/metrics`
  custom). Ne pas y attacher une DB ou un service sans raison — pas de
  gain, juste plus de surface réseau exposée.

---

## 3. Bugs rencontrés et fixés — chronologie

| # | Symptôme | Cause | Fix | Commit |
|---|----------|-------|-----|--------|
| 1 | `set: Illegal option -o pipefail` | `#!/bin/sh` mais `/bin/sh` = dash sur le serveur, `pipefail` est bash-only | Shebang `#!/usr/bin/env bash` | `c61ab75` |
| 2 | `pull access denied` sur `crowdsecurity/firewall-bouncer` | Nom d'image inventé — **aucune image Docker officielle n'existe** pour `cs-firewall-bouncer` (CrowdSec le distribue en paquet natif + systemd, car il manipule iptables/nftables sur l'hôte) | Service retiré du compose ; `crowdsec` publie sa LAPI sur `127.0.0.1:8080` ; bouncer installé nativement via `scripts/setup-crowdsec.sh` (apt + `cscli bouncers add`) | `43ed1db` |
| 3 | `crowdsec`: `cannot unmarshal !!map into string` sur `profiles.yaml`, LAPI ne démarre jamais | Schéma `profiles.yaml` invalide dès l'origine (`filters` était une liste de `{alert_id, decisions}`, alors que CrowdSec attend une liste d'**expressions** `expr`) | Remplacé par le `profiles.yaml` par défaut officiel CrowdSec (ban 4h générique sur `Alert.Remediation == true`) | `c6ed60c` |
| 4 | `grafana` crash-loop : `Error: ✗ invalid setting [alerting].enabled` | Grafana 13 a supprimé le legacy alerting, erreur fatale si `[alerting]` est présent dans `grafana.ini` | Section `[alerting]` retirée, `[unified_alerting].enabled = true` suffit (déjà présent) | `9a9d107` |
| 5 | `loki`: `CONFIG ERROR: invalid compactor config: compactor.delete-request-store should be configured` | Loki récent exige `delete_request_store` dès que `retention_enabled: true` | Ajout `delete_request_store: filesystem` dans `loki.yml` | `37c0771` |
| 6 | `watchtower-*`: `client version 1.25 is too old. Minimum supported API version is 1.40` | `containrrr/watchtower` (projet non maintenu) négocie une trop vieille version d'API Docker | `DOCKER_API_VERSION: "1.41"` forcé en env sur les deux instances | `37c0771` |
| 7 | `docker login` CI → `400 Bad Request` sur le registre | `registry/docker-compose.yml` monte `./htpasswd` **relatif au dossier du fichier compose** (`registry/htpasswd`), qui n'a jamais existé → Docker crée un **dossier vide** à la place → auth cassée | Copier/régénérer le vrai htpasswd à `registry/htpasswd` (pas à la racine du repo) | — (fix serveur, pas de commit — fichier gitignoré) |
| 8 | `loki`: `mkdir /data/loki/chunks: permission denied`, puis `creating WAL folder at "/wal": mkdir wal: permission denied` | L'image `grafana/loki` tourne en UID `10001` (non-root) ; le volume nommé `/data/loki` est créé `root` par défaut, et le WAL par défaut (`/wal`) vit sur la couche éphémère du container (pas dans le volume monté, donc pas couvert par le chown) | Service `loki-init` (alpine, `chown -R 10001:10001 /data/loki`) avant `loki` via `depends_on: condition: service_completed_successfully` ; **et** `ingester.wal.dir: /data/loki/wal` dans `loki.yml` pour que le WAL vive dans le même volume déjà chowné (bonus : survit à un `--force-recreate`). Confirmé résolu. | `b751aee`, `1633b82` |
| 9 | Dashboard **Portfolio** : "An error occurred within the plugin" | **Ouvert / non résolu** — probablement le panel `table` sur `ALERTS{alertstate="firing"}` (transformation manquante), ou format datasource string legacy incompatible Grafana 13 | À investiguer : `docker logs grafana \| grep -i error`, identifier le panel exact | — |

---

## 4. Dashboards Grafana provisionnés

Chargés automatiquement depuis `monitoring/grafana/dashboards/*.json`
(provider `file`, dossier `default`, tout fichier du dossier est
provisionné — pas besoin de les lister dans `dashboards.yaml`).

| Dashboard | UID | Contenu |
|---|---|---|
| Poker Training | `poker-training-main` | CPU/RAM/disque host, containers actifs, requêtes Traefik globales |
| Logs — Poker Training | `poker-training-logs` | Logs Loki filtrés, SSH bruteforce, HTTP 4xx/5xx |
| CrowdSec — Sécurité | — | Métriques CrowdSec |
| **Infra — Erreurs & Crash-loops** | `infra-errors` | Redémarrages par container (détection crash-loop), logs erreur/warning des services d'infra, alertes Alertmanager actives |
| **Portfolio** | `portfolio-main` | CPU/RAM par container `portfolio-{prod,staging}-*`, requêtes/latence/codes par router Traefik, logs erreur + live tail |

⚠️ Les panels "par router" du dashboard Portfolio nécessitent
`addRoutersLabels: true` dans `traefik.yml` (`metrics.prometheus`) — sans
ça, `traefik_router_*` n'a pas de label `router` exploitable et les
panels restent vides.

---

## 5. Commandes de déploiement — cheat-sheet

```bash
# Infra partagée (une fois les .env remplis)
cd ~/deploy_ci_cd
./scripts/deploy.sh networks     # crée traefik-web + monitoring-network
./scripts/deploy.sh traefik
./scripts/deploy.sh monitoring
./scripts/deploy.sh registry
./scripts/deploy.sh watchtower
./scripts/deploy.sh all          # tout sauf les apps

# Recréer un seul service après un fix de config
docker compose -f monitoring/compose.monitoring.yml \
  --env-file monitoring/.env.monitoring up -d --force-recreate <service>

# Apps (depuis leur propre repo, pas depuis deploy_ci_cd)
cd ~/portfolio/deploy   # ou équivalent poker_training
docker compose -f compose.yml --env-file .env.prod up -d
```

---

## 6. Checklist de debug générique

Face à un nouveau problème, dans l'ordre :

1. **Le container tourne ?**
   ```bash
   docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
   ```
   `Restarting (N)` → crash-loop, aller direct aux logs.

2. **Logs du container** :
   ```bash
   docker logs <container> --tail 50
   ```
   Ou depuis Grafana Explore (Loki) — pas besoin d'accès serveur une fois
   que promtail tourne :
   ```logql
   {container_name="<container>"} |~ "(?i)error|fatal|panic"
   ```

3. **Le compose est syntaxiquement valide ?**
   ```bash
   docker compose -f <fichier> config -q
   ```

4. **Le réseau existe et le container y est bien attaché ?**
   ```bash
   docker network ls | grep -E 'monitoring|traefik'
   docker network inspect <network> --format '{{range .Containers}}{{.Name}} {{end}}'
   ```

5. **Le fichier `.env` attendu existe ?** (`docker compose --env-file`
   échoue silencieusement / avec erreur peu claire si le fichier est
   absent)

6. **Datasource Grafana OK ?** Connections → Data sources → bouton
   "Test" sur Prometheus et Loki.

7. **Le commit qui corrige le problème a-t-il été pushé ET pullé côté
   serveur ?** Piège rencontré plusieurs fois cette session : un fix
   local jamais poussé, ou poussé sur la mauvaise branche (vérifier
   `git branch -vv` avant de pousser si le repo a plusieurs branches
   actives).

---

## 7. Rotation des secrets — état

- `traefik/acme.json` — jamais tourné depuis la centralisation (recommandé
  mais pas fait : `touch` + `chmod 600` pour forcer une réémission).
- `htpasswd` (registry) — régénéré pendant cette session, à confirmer
  que le secret GitHub Actions correspondant est à jour.
- `deploy/htpasswd` (racine, ancien, non référencé par aucun compose) —
  supprimé, plus d'usage.

## 8. Items ouverts

- [ ] Dashboard Portfolio : erreur plugin sur un panel (#9 ci-dessus) —
      identifier lequel et corriger.
- [ ] `alertmanager` (exit 127 observé une fois) — logs jamais fournis,
      diagnostic pas terminé.
- [ ] `log.level: DEBUG` dans `traefik.yml` — proposé de passer à `INFO`
      (bruit inutile dans Loki + CrowdSec), pas encore fait, en attente
      de confirmation.
- [ ] Escalade de durée de ban CrowdSec par scénario (1h scan, 2h bad-UA,
      permanent après 3 bans) — l'ancien `profiles.yaml` le prévoyait mais
      avec une syntaxe invalide (jamais fonctionnel). Le fix actuel utilise
      le profil générique par défaut (4h). Réimplémentable proprement avec
      `Alert.GetScenario() == '...'` si voulu.
- [ ] Rotation `acme.json`.
