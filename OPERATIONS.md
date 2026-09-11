# Portfolio — Opérations / Mémos

## Redéploiement manuel

```bash
# Prod
docker compose -f compose.yml --env-file .env.prod up -d

# Staging
docker compose -f compose.yml --env-file .env.staging up -d
```

Les images sont poussées sur `registry.bachelart.fr` avec les tags `latest-prod` / `latest-staging`.

---

## Routage Traefik — collision prod / staging (⚠️ IMPORTANT)

### Problème résolu

Les stacks **prod** et **staging** partagent le même réseau Traefik (`traefik-web`). Si deux routeurs portent le **même nom**, le dernier conteneur démarré écrase silencieusement la config de l'autre → 404 sur le domaine concerné.

### Cause

```yaml
# ❌ AVANT — collision : les deux stacks créent le même routeur "portfolio"
traefik.http.routers.portfolio.rule=Host(`www.${FRONTEND_HOST}`)
```

### Solution

```yaml
# ✅ APRÈS — chaque stack a son propre suffixe ${ENV}
traefik.http.routers.portfolio-${ENV}.rule=Host(`www.${FRONTEND_HOST}`)
traefik.http.routers.portfolio-${ENV}-apex.rule=Host(`${FRONTEND_HOST}`)
```

Avec les `.env` :
- `.env.prod`    → `ENV=prod`     → routeurs `portfolio-prod`, `portfolio-prod-apex`
- `.env.staging` → `ENV=staging`  → routeurs `portfolio-staging`, `portfolio-staging-apex`

### Règle d'or

**Tout nouveau label Traefik dans `deploy/compose.yml` doit inclure `${ENV}` dans le nom du routeur.**

✅ Avec `${ENV}` :
```yaml
traefik.http.routers.mon-app-${ENV}.rule=Host(`sous-domaine.${FRONTEND_HOST}`)
```

❌ Sans `${ENV}` (collision garantie) :
```yaml
traefik.http.routers.mon-app.rule=Host(`sous-domaine.${FRONTEND_HOST}`)
```

Exceptions — éléments qui n'ont pas besoin de suffixe :
- Les `middlewares` (nommés par le service, pas partagés entre stacks)
- Le label `traefik.enable=true`
- Les labels `traefik.http.services.*` (on les supprime complètement — Traefik auto-génère les noms)

---

## Ordre de déploiement

Pour minimiser les interruptions :

1. **Prod d'abord** (elle réenregistre ses routeurs)
2. **Staging ensuite** (il ajoute ses routeurs sans conflit)

```bash
# 1. Prod
docker compose -f compose.yml --env-file .env.prod up -d

# 2. Staging (attendre que la prod réponde)
docker compose -f compose.yml --env-file .env.staging up -d
```

---

## Checklist : ajouter un nouveau service au routage Traefik

- [ ] Le nom du routeur inclut `${ENV}` (ex. `portfolio-${ENV}-mon-sous-domaine`)
- [ ] Pas de label `traefik.http.services.*` explicite (Traefik auto-génère)
- [ ] Le `container_name` inclut `${COMPOSE_PROJECT_NAME}` pour éviter les collisions de noms
- [ ] Tester staging puis prod sans down de l'autre

---

## Ports

| Service | Port interne | Exposition host |
|---------|-------------|-----------------|
| PostgreSQL (local) | 5432 | 5433 (pour éviter conflit avec poker-training) |
| PostgreSQL (serveur) | 5432 | Aucune (réseau Docker interne seulement) |
| Next.js | 3000 | Aucune (Traefik fait le routage) |

---

## Watchtower — Auto-redéploiement automatique 🚀

Watchtower scrute le registre Docker toutes les 5 minutes et redéploie
automatiquement les conteneurs quand une nouvelle image est poussée.

### Architecture

```
CI/CD (push image)
       ↓
  Registry (registry.bachelart.fr)
       ↓
  Watchtower (scrute toutes les 5 min)
       ↓
  Redémarre le conteneur avec la nouvelle image
```

- **Prod** → `watchtower-prod` (scope=prod) → redémarre vraiment
- **Staging** → `watchtower-staging` (scope=staging) → mode dry-run (monitor only)

### Labels requis sur les conteneurs cibles

Chaque service dans `compose.yml` qui doit être surveillé a ces labels :

```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=true"
  - "com.centurylinklabs.watchtower.scope=${ENV}"
```

Actuellement actifs sur : `database` et `nextjs`.

### Déploiement de Watchtower

```bash
# Vérifier que watchtower n'est pas déjà en cours
docker ps --filter name=watchtower

# Lancer (un fichier unique pour les deux instances)
docker compose -f compose.watchtower.yml up -d

# Vérifier les logs
docker logs watchtower-prod --tail 20
docker logs watchtower-staging --tail 20

# Forcer un scan immédiat
docker exec watchtower-prod watchtower --run-once
docker exec watchtower-staging watchtower --run-once

# Arrêter Watchtower
docker compose -f compose.watchtower.yml down
```

### Mise en garde : database (PostgreSQL)

Watchtower surveille aussi `database` (postgres:16-alpine).  
Si PostgreSQL est mis à jour, il redémarrera sur la nouvelle image mineure.

⚠️ **Cela n'affecte PAS les données** — le volume `db_data` est préservé.
Mais il y a une coupure réseau de quelques secondes pendant le redémarrage.
Next.js a une dépendance `depends_on: database: condition: service_healthy`,
donc il ne redémarrera qu'après que Postgres soit prêt.

### Activation du redéploiement automatique (workflow parfait)

1. Pousser les changements sur GitHub
2. La CI build et push l'image sur `registry.bachelart.fr:tag`
3. Watchtower détecte la nouvelle image (~5 min max)
4. Watchtower redémarre le conteneur nextjs avec l'image fraîche
5. Le site est mis à jour sans intervention humaine

### Mode dry-run staging

En staging, Watchtower tourne en `WATCHTOWER_MONITOR_ONLY: true` par défaut.
Il détecte les nouvelles images et notifie (logs), mais **ne redémarre pas**.

Pour activer le redéploiement staging :
```yaml
# compose.watchtower.yml → service watchtower-staging
WATCHTOWER_MONITOR_ONLY: false
```
Puis `docker compose -f compose.watchtower.yml up -d` pour appliquer.

### Checklist ajout d'un service

- [ ] Label `com.centurylinklabs.watchtower.enable=true` sur le service
- [ ] Label `com.centurylinklabs.watchtower.scope=\${ENV}` (scope par environnement)
- [ ] Vérifier que le redémarrage du service est safe (perte de données ? interruption ?)