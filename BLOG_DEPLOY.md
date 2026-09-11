# Mettre en production une app Laravel + Next.js sur un VPS Oracle ARM

**Comment j'ai construit le pipeline de déploiement de Poker Training — de `git push` à `https://app.bachelart.fr`**

---

## TL;DR

5 services Docker (PostgreSQL, Laravel FPM, nginx, Next.js, solver-worker Rust), un registry privé, Traefik avec Let's Encrypt, et un pipeline CI/CD GitHub Actions multi-arch qui build sur ARM et déploie sur staging puis prod.

---

## Le problème de départ

J'avais une app Laravel + Next.js qui tournait en local avec Docker Compose. Pour la mettre en ligne, il fallait :

1. Héberger sur un VPS Oracle ARM (graviton, architecture `linux/arm64`)
2. Automatiser le build et le déploiement
3. Gérer les certificats TLS, le registry privé, les secrets
4. Ne pas exposer la base de données ni les fichiers source sur le serveur

---

## Étape 1 — L'infrastructure Docker locale

**Commit : `b21bef3` — feat(docker): configure nginx and Docker infrastructure for backend**

Tout commence par un `docker-compose.yml` local avec trois services :

- **backend** : PHP 8.3 FPM avec Composer, Xdebug optionnel
- **nginx** : Alpine, sert le dossier `public/` et proxy vers FPM
- **db** : PostgreSQL 16 Alpine

```yaml
# backend/docker-compose.yml (version initiale)
services:
  backend:
    build:
      context: .
      args:
        USER_ID: ${USER_ID:-1000}
        GROUP_ID: ${GROUP_ID:-1000}
    container_name: poker-training-app
    volumes:
      - .:/var/www/html
    environment:
      - APP_ENV=local
      - APP_KEY=${APP_KEY}
      - DB_CONNECTION=pgsql
      - DB_HOST=db
      - DB_PORT=5432
      - DB_DATABASE=${DB_DATABASE}
      - DB_USERNAME=${DB_USERNAME}
      - DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      db:
        condition: service_healthy
```

Le Dockerfile backend est un multi-stage manuel : Composer install, key:generate, optimisation autoload.

```dockerfile
FROM php:8.3-fpm
# ... extensions pdo_pgsql, mbstring, zip, exif, pcntl
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-scripts
COPY . .
RUN php artisan key:generate --force
```

**Piège évité** : le `composer install` est fait dans le Dockerfile, pas à chaud dans le conteneur. Ça signifie que l'image contient TOUT le code — le serveur n'a besoin que de l'image, pas du repo git.

---

## Étape 2 — Les workflows GitHub Actions

**Commit : `f36e355` — ci(workflows): add GitHub Actions workflows**

7 workflows pour couvrir tout le cycle :

| Workflow | Déclencheur | Rôle |
|----------|-------------|------|
| `ci.yml` | push PR sur develop | Tests + lint + PHPStan |
| `deploy.yml` | push sur main | Déploiement staging puis prod |
| `test.yml` | workflow_call | Tests unitaires réutilisables |
| `quality.yml` | workflow_call | Pint + PHPStan |
| `audit.yml` | cron hebdo | `composer audit` |
| `migration.yml` | manuel | `php artisan migrate` sur serveur |
| `maintenance.yml` | manuel | `php artisan down/up` |

Le CI initial est simple mais efficace :

```yaml
# .github/workflows/ci.yml
jobs:
  ci:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: obsidian_web_test
          POSTGRES_PASSWORD: obsidian_web_secret
          POSTGRES_USER: obsidian_web
    steps:
      - uses: actions/checkout@v4
      - name: Setup PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: 8.3
          extensions: pdo_pgsql, intl, zip
      - name: Install dependencies
        run: composer install
      - name: Lint (Pint)
        run: ./vendor/bin/pint --test
      - name: PHPStan
        run: ./vendor/bin/phpstan analyse --level=6
      - name: Run migrations
        run: php artisan migrate --force
      - name: PHPUnit
        run: php artisan test --testsuite=Feature,Unit
```

**Leçon apprise** : le `--testsuite` doit être en **minuscules** dans `phpunit.xml` (`feature`, `unit`), sinon GitHub Actions casse silencieusement. Commit `f4242bd`.

---

## Étape 3 — Le registry privé Docker

**Commit : `5adaf6d` — infra(deploy): add traefik and registry compose files**

Pour ne pas passer par Docker Hub (limité, public), j'héberge mon propre registry Docker sur le VPS, derrière Traefik.

### Traefik — le reverse proxy avec TLS automatique

```yaml
# deploy/traefik/docker-compose.yml
services:
  traefik:
    image: traefik:v3
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./acme.json:/acme.json
```

La config Traefik est minimaliste mais complète :

```yaml
# deploy/traefik/traefik.yml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true'
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: luc.bachelerieart@gmail.com
      storage: /acme.json
      httpChallenge:
        entryPoint: web
```

**Astuce** : `acme.json` doit avoir les permissions `600` et être monté en读写 — Traefik y écrit les certificats Let's Encrypt.

### Registry — stockage privé des images

```yaml
# deploy/registry/docker-compose.yml
services:
  registry:
    image: registry:2
    environment:
      REGISTRY_AUTH: htpasswd
      REGISTRY_AUTH_HTPASSWD_PATH: /auth/htpasswd
    volumes:
      - registry_data:/var/lib/registry
      - ./htpasswd:/auth/htpasswd:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry.rule=Host(`registry.bachelart.fr`)"
      - "traefik.http.routers.registry.entrypoints=websecure"
      - "traefik.http.routers.registry.tls.certresolver=letsencrypt"
```

**Piège évité** : le fichier `htpasswd` doit exister sur le serveur AVANT de démarrer le registry. Sans lui, le registry rejette toutes les connexions avec `400 Bad Request`. J'ai perdu 30 minutes à debugguer ça.

---

## Étape 4 — Le `compose.yml` de production

**Même commit : `5adaf6d`**

Le fichier `deploy/compose.yml` orchestre 5 services :

```
┌─────────────┐     ┌──────────────┐
│   Traefik   │────▶│   Registry   │
│  (reverse    │     │  (images)    │
│   proxy)     │     └──────────────┘
└──────┬───────┘
       │
  ┌────┴──────────┐
  │  traefik-web  │  (réseau externe partagé)
  └────┬──────────┘
       │
  ┌────┴────┐   ┌──────────┐   ┌───────────┐
  │  nginx  │   │ frontend │   │  solver-  │
  │ (proxy  │   │ (Next.js)│   │  worker   │
  │  API)   │   └──────────┘   │  (Rust)   │
  └────┬────┘                  └───────────┘
       │
  ┌────┴──────┐   ┌──────────┐
  │  backend  │──▶│ database │
  │ (Laravel  │   │(Postgres)│
  │   FPM)    │   └──────────┘
  └───────────┘
```

Points clés du `compose.yml` :

- **Toutes les images** viennent du registry privé (`registry.bachelart.fr/backend:${IMAGE_TAG}`)
- **Les volumes** sont nommés avec le préfixe `${ENV}` (`staging_db_data`, `prod_db_data`) pour isoler les environnements
- **Les clés OAuth** sont dans un volume séparé monté en read-only (`oauth-keys`)
- **Les arbres de solveur** sont persistés dans `solver-trees`
- **Traefik labels** sur nginx et frontend pour le routage TLS

```yaml
# Extrait — routage Traefik
nginx:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.nginx.rule=Host(`api.${FRONTEND_HOST}`)"
    - "traefik.http.routers.nginx.entrypoints=websecure"
    - "traefik.http.routers.nginx.tls.certresolver=letsencrypt"

frontend:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.frontend.rule=Host(`app.${FRONTEND_HOST}`)"
    - "traefik.http.routers.frontend.entrypoints=websecure"
    - "traefik.http.routers.frontend.tls.certresolver=letsencrypt"
```

---

## Étape 5 — Les Dockerfiles de production

### Backend Laravel (multi-stage)

Le Dockerfile backend a évolué pour devenir un build de production complet :

```dockerfile
FROM php:8.3-fpm

# Installer les dépendances système
RUN apt-get update && apt-get install -y \
    libpq-dev libzip-dev libonig-dev unzip \
    && docker-php-ext-install pdo_pgsql mbstring zip exif pcntl

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Installer les dépendances Composer (sans dev)
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-scripts

# Copier le code source
COPY . .

# Générer APP_KEY, découvrir les packages
RUN php artisan key:generate --force \
    && php artisan package:discover --ansi
```

**Décision** : le `.env` est généré à la volée puis supprimé — les vraies variables viennent du `compose.yml` au runtime.

### Frontend Next.js (3 stages)

```dockerfile
# Stage 1: deps — installer les dépendances
FROM node:20-alpine AS deps
RUN npm install -g pnpm@9.0.0
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Stage 2: builder — compiler Next.js
FROM node:20-alpine AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
RUN pnpm --filter @repo/web build

# Stage 3: runtime — image minimale
FROM node:20-alpine AS runner
COPY --from=builder --chown=nextjs:nodejs \
  /app/apps/web/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs \
  /app/apps/web/.next/static ./apps/web/.next/static
USER nextjs
```

**Astuce** : Next.js en `output: standalone` produit un dossier autonome avec tout le nécessaire — pas besoin de node_modules au runtime.

### Solver Worker Rust

```dockerfile
FROM rust:1-slim AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/solver-worker /usr/local/bin/solver-worker
ENTRYPOINT ["solver-worker"]
```

**Pourquoi Rust en production ?** Le solveur DCFR (Discounted CFR) est un calcul intensif — Rust est 50× plus rapide que PHP pour ce workload. L'image finale fait ~30 MB.

### Nginx (proxy statique)

```dockerfile
FROM nginx:alpine
COPY backend/public /var/www/html/public
COPY backend/docker/nginx/default.conf /etc/nginx/conf.d/default.conf
```

**Décision** : le dossier `public/` et la config nginx sont **baked dans l'image**. Le serveur n'a pas besoin du code source Laravel — seulement l'image.

---

## Étape 6 — Le pipeline CI/CD complet

**Commit : `dc01a9a` — ci(deploy): multi-arch build and push to self-hosted registry**

Le workflow final a 4 jobs :

```
changes → build → deploy-staging → deploy-prod
```

### Job `changes` — détection intelligente

Utilise `dorny/paths-filter` pour ne builder que ce qui a changé :

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      app: ${{ steps.filter.outputs.app }}
      deploy: ${{ steps.filter.outputs.deploy }}
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            app:
              - 'backend/**'
              - 'frontend/**'
              - 'solver-worker/**'
              - 'deploy/nginx/**'
            deploy:
              - 'deploy/**'
              - '.github/workflows/deploy.yml'
```

### Job `build` — multi-arch ARM64

Le build se fait sur un runner `ubuntu-24.04-arm` (ARM natif) :

```yaml
build:
  runs-on: ubuntu-24.04-arm
  needs: changes
  if: needs.changes.outputs.app == 'true' || inputs.force_rebuild == true
  steps:
    - uses: docker/login-action@v4
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ secrets.REGISTRY_USER }}
        password: ${{ secrets.REGISTRY_PASSWORD }}

    - name: Build and push backend
      uses: docker/build-push-action@v7
      with:
        context: ./backend
        platforms: linux/arm64
        push: true
        tags: |
          ${{ env.REGISTRY }}/backend:${{ github.sha }}
          ${{ env.REGISTRY }}/backend:latest-staging
```

**Tags** : le SHA du commit + `latest-staging` ou `latest-prod` selon la branche.

### Job `deploy-staging` — SSH + rsync + docker compose

```yaml
deploy-staging:
  needs: [changes, build]
  if: github.ref == 'refs/heads/develop'
  steps:
    - name: Sync deploy files
      run: |
        rsync -avz --delete \
          --exclude='.env.*' --exclude='acme.json' --exclude='htpasswd' \
          deploy/ oracle:/home/deploy/poker-training/deploy/

    - name: Deploy on staging
      run: |
        ssh oracle << 'REMOTE_EOF'
          cd /home/deploy/poker-training/deploy
          source .env.staging
          export IMAGE_TAG=${{ github.sha }}
          docker compose --env-file .env.staging -f compose.yml pull
          docker compose --env-file .env.staging -f compose.yml up -d
          curl -sf https://api.staging.bachelart.fr
        REMOTE_EOF
```

**Rollback intégré** : avant de déployer, le script sauvegarde le tag précédent dans `.last-known-good-staging`.

### Job `deploy-prod` — chaîné après staging

```yaml
deploy-prod:
  needs: [changes, build, deploy-staging]
  if: github.ref == 'refs/heads/main'
  environment: production
```

**Règle** : on ne déploie en prod que si le staging a réussi. La prod utilise `.env.prod` et le domaine `bachelart.fr` (sans préfixe `staging.`).

---

## Étape 7 — Les secrets et l'initialisation

### OAuth Keys

Les clés RSA de Laravel Passport sont générées une fois par environnement via un script dédié :

```bash
# deploy/scripts/init-oauth-keys.sh
docker compose --env-file .env.staging -f compose.yml run --rm \
  --no-deps --user root \
  --volume "oauth-keys:/oauth-keys" \
  backend \
  -c '
    php artisan passport:keys --force
    cp /var/www/html/storage/oauth-private.key /oauth-keys/private.pem
    cp /var/www/html/storage/oauth-public.key /oauth-keys/public.pem
  '
```

**Pourquoi un script séparé ?** Les clés doivent être persistantes entre les déploiements (sinon tous les tokens OAuth expirent). Le volume `oauth-keys` est monté en read-only dans le `compose.yml`.

### Variables d'environnement

Deux fichiers template versionnés (`.env.prod.example`, `.env.staging.example`) documentent toutes les variables requises. Les vrais `.env.prod` et `.env.staging` sont gitignorés.

```bash
# Secrets à générer une fois
APP_KEY=base64:$(openssl rand -base64 32)
APP_SECRET=$(openssl rand -base64 32)
OAUTH_ENCRYPTION_KEY=base64:$(openssl rand -base64 32)
AUTH_SECRET=$(openssl rand -base64 32)
OAUTH_CLIENT_SECRET=$(openssl rand -hex 32)
```

---

## Architecture finale

```
┌─────────────────────────────────────────────────────────┐
│                    VPS Oracle ARM                        │
│                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────────────┐   │
│  │  Traefik  │───▶│ Registry │    │  GitHub Actions  │   │
│  │  :443     │    │  :5000   │    │  (build ARM64)   │   │
│  └─────┬─────┘    └──────────┘    └────────┬─────────┘   │
│        │                                    │            │
│  ┌─────┴─────────────────────────────────────┘            │
│  │           docker pull registry.bachelart.fr/...        │
│  │                                                        │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐     │
│  │  │  nginx    │  │ frontend │  │  solver-worker   │     │
│  │  │  (API)    │  │ (Next.js)│  │  (Rust CFR)      │     │
│  │  └─────┬─────┘  └──────────┘  └──────────────────┘     │
│  │        │                                                │
│  │  ┌─────┴─────┐  ┌──────────┐                           │
│  │  │  backend   │  │ database │                           │
│  │  │ (Laravel)  │  │(Postgres)│                           │
│  │  └───────────┘  └──────────┘                           │
│  │                                                        │
│  │  Volumes : db_data, oauth-keys, solver-trees           │
│  └────────────────────────────────────────────────────────┘
```

---

## Ce que j'ai appris

1. **Bake tout dans l'image** — le serveur n'a besoin que de Docker, pas du code source ni de Composer/npm
2. **Registry privé** — évite les limites de Docker Hub, contrôle total
3. **Traefik + Let's Encrypt** — TLS automatique, zéro maintenance
4. **Multi-arch ARM** — Oracle ARM est 80% moins cher que les instances AMD, et GitHub Actions supporte les runners ARM natifs
5. **Pipeline chaîné** — staging d'abord, prod ensuite, rollback tag sauvegardé
6. **Volumes nommés** — isolement staging/prod par préfixe `${ENV}_`

---

## Les commits clés

| Date | Commit | Sujet |
|------|--------|-------|
| 2026-05-11 | `09bbaee` | Initial Laravel 11 project scaffold |
| 2026-05-12 | `f36e355` | CI workflows (7 workflows) |
| 2026-07-05 | `b21bef3` | Docker infrastructure (nginx + backend) |
| 2026-07-03 | `4ad1319` | Rebrand obsidian → poker-training |
| 2026-08-21 | `5adaf6d` | Traefik + registry + compose.yml |
| 2026-08-21 | `dc01a9a` | Multi-arch CI/CD pipeline |

---

*Code source : [github.com/luckarts/laravel_obsidian](https://github.com/luckarts/laravel_obsidian) — branche `feature/deploy_prod_oracle`*
