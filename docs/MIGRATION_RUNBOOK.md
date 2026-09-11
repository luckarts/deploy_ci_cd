# Runbook — Migration vers le monitoring centralisé

À exécuter **sur le serveur**, dans l'ordre. Chaque étape a une commande de
vérification avant de passer à la suivante.

---

## 0. Pré-requis

```bash
# Cloner le nouveau repo centralisé (si pas déjà fait)
git clone https://github.com/luckarts/deploy_ci_cd.git ~/deploy
cd ~/deploy

# Remplir les fichiers d'env réels (jamais commités)
cp .env.prod.example .env.prod && vim .env.prod
cp .env.staging.example .env.staging && vim .env.staging
cp monitoring/.env.monitoring.example monitoring/.env.monitoring && vim monitoring/.env.monitoring
```

`traefik/acme.json` et `htpasswd` : voir étape 3 (rotation), ne pas les
recopier tels quels depuis l'ancien serveur.

---

## 1. Inventaire — avant de toucher à quoi que ce soit

```bash
# Liste tous les projets docker compose actifs
docker compose ls

# Liste tous les containers avec leur projet et réseau
docker ps --format 'table {{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}'

# Détail des réseaux
docker network ls | grep -E 'monitoring|traefik'
```

Note quelque part les noms exacts de projets trouvés (ex. `monitoring`,
`poker-training-staging`) — ils servent aux commandes `down` ci-dessous.
Les noms peuvent différer de ce qui a été observé précédemment ; se fier à
la sortie réelle de `docker compose ls`.

---

## 2. Arrêter les deux anciennes stacks monitoring

Deux stacks à arrêter séparément : l'ancien monitoring "portfolio seul"
(projet `monitoring`, ne contenait que Grafana) et le monitoring embarqué
dans `poker_training` (projet `poker-training-staging`, contenait
prometheus/promtail/cadvisor/grafana).

```bash
# Ancien monitoring "portfolio" (grafana seul)
cd /chemin/vers/ancien/portfolio/deploy/monitoring   # adapter le chemin
docker compose -p monitoring down            # sans -v : garde les volumes au cas où

# Monitoring embarqué dans poker_training
cd /chemin/vers/poker_training/deploy/monitoring     # adapter le chemin
docker compose -p poker-training-staging down        # sans -v
```

Vérifier qu'il ne reste plus rien qui utilise les anciens réseaux/ports :

```bash
docker ps -a | grep -E 'prometheus|loki|grafana|promtail|cadvisor|alertmanager|crowdsec'
# → doit être vide (ou uniquement les nouveaux containers si déjà relancés)

docker network ls | grep monitoring
# → ne doit plus lister monitoring_monitoring-network ni
#   poker-training-staging_monitoring-network
```

**Ne pas supprimer les volumes** (`grafana-data`, `loki-data`, etc.) tant
que la nouvelle stack n'est pas confirmée fonctionnelle — au pire on perd
l'historique des dashboards/métriques, pas grave, mais pas de raison de
se presser. Une fois la nouvelle stack validée (étape 5), nettoyer :

```bash
docker volume ls | grep -E 'grafana-data|loki-data|crowdsec'
docker volume rm <volumes_orphelins_des_anciens_projets>
```

---

## 3. Rotation des secrets (acme.json, htpasswd)

Ces deux fichiers étaient commités dans l'historique git de `my-app`
(repo privé — exposition limitée aux collaborateurs GitHub, mais autant
les régénérer proprement dans le nouveau setup).

### acme.json (certificats Let's Encrypt)

```bash
# Sur le serveur, dans le dossier traefik du nouveau deploy/
touch ~/deploy/traefik/acme.json
chmod 600 ~/deploy/traefik/acme.json
```

Fichier vide + permissions 600 → Traefik régénère tous les certificats au
prochain démarrage (léger downtime TLS le temps du re-challenge ACME,
quelques secondes par domaine).

### htpasswd (dashboard Traefik)

```bash
# Génère un nouveau hash bcrypt pour l'utilisateur admin
docker run --rm httpd:alpine htpasswd -nbB admin '<NOUVEAU_MOT_DE_PASSE>' > ~/deploy/htpasswd
chmod 600 ~/deploy/htpasswd
```

Remplacer `<NOUVEAU_MOT_DE_PASSE>` par un mot de passe fort généré
(`openssl rand -base64 24`), le noter dans le gestionnaire de mots de
passe.

Les deux fichiers restent dans `.gitignore` du nouveau repo — ne jamais
les commiter.

---

## 4. Nettoyer `deploy/` du repo `my-app`

Le dossier `deploy/` dans `my-app` est maintenant dupliqué/obsolète —
toute la config vit dans `deploy_ci_cd`.

```bash
cd /home/luc/Documents/portfolio_2026/my-app
git rm -r deploy
git commit -m "chore: remove deploy/ — migrated to deploy_ci_cd repo"
git push
```

Ne pas supprimer `BLOG_DEPLOY.md` ni `OPERATIONS.md` sans vérifier qu'ils
ont bien été copiés dans le nouveau repo (ils le sont — commit `c0c956f`
de `deploy_ci_cd`).

---

## 5. Déployer la stack unifiée

```bash
cd ~/deploy
./scripts/deploy.sh all       # réseaux + traefik + monitoring + portfolio prod
./scripts/deploy.sh staging   # si besoin de l'environnement staging aussi
```

Vérification :

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
# tous les containers attendus doivent être "healthy" ou "Up"

docker network inspect monitoring-network --format '{{range .Containers}}{{.Name}} {{end}}'
# doit lister : prometheus, grafana, loki, promtail, cadvisor, alertmanager,
# crowdsec, traefik, <projet>-nextjs
```

Ouvrir `https://monitoring.bachelart.fr` (Grafana) — vérifier que les
datasources Prometheus et Loki répondent (Grafana → Connections → Data
sources → "Test").

---

## 6. Relier `poker_training` au monitoring

`promtail` et `cadvisor` voient déjà **tous** les containers du serveur
sans configuration supplémentaire (ils lisent le socket Docker / les
cgroups directement, pas besoin d'être sur le même réseau Docker). Donc
dès que la stack unifiée tourne, les logs et métriques CPU/RAM/réseau de
poker_training apparaissent automatiquement dans Grafana (filtrer par
label `compose_project` dans Loki, ou par nom de container dans le
dashboard cAdvisor).

Ce qui **ne** vient pas automatiquement : le scraping Prometheus d'un
éventuel endpoint `/metrics` applicatif de poker_training. Si ce service
expose des métriques custom :

1. Attacher le service au réseau externe `monitoring-network` dans son
   propre `compose.yml` (même pattern que `nextjs` dans le compose
   portfolio) :

   ```yaml
   services:
     poker-training-app:
       networks:
         - app-network       # réseau interne existant, ne pas retirer
         - monitoring-network

   networks:
     monitoring-network:
       external: true
   ```

2. Ajouter un job dans `monitoring/prometheus/prometheus.yml` :

   ```yaml
   - job_name: 'poker-training'
     static_configs:
       - targets: ['poker-training-app:<PORT_METRICS>']
   ```

3. `docker compose -f monitoring/compose.monitoring.yml up -d prometheus`
   pour recharger la config sans tout redémarrer (ou `--web.enable-lifecycle`
   permet aussi un reload à chaud via `curl -X POST http://localhost:9090/-/reload`).

Si poker_training n'expose pas de `/metrics`, rien à faire ici — logs et
métriques infra sont déjà couverts par promtail/cadvisor.

---

## Rollback

Si la nouvelle stack pose problème : `docker compose -f <fichier> down`
sur ce qui a été lancé à l'étape 5, puis relancer les anciennes stacks
depuis leurs dossiers d'origine (elles n'ont pas été supprimées, juste
arrêtées à l'étape 2 — sans `-v`, les volumes/données sont intacts).
