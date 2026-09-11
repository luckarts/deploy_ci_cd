#!/bin/sh
# deploy.sh — Déploiement manuel depuis le dossier deploy/ centralisé.
# Usage : ./deploy.sh <networks|traefik|monitoring|prod|staging|all>
#
# Workflow serveur :
#   cd deploy && git pull
#   ./scripts/deploy.sh all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ensure_network() {
  docker network inspect "$1" >/dev/null 2>&1 || docker network create "$1"
}

case "${1:-help}" in
  networks)
    echo "🔌 Vérification des réseaux partagés..."
    ensure_network traefik-web
    ensure_network monitoring-network
    echo "✅ traefik-web + monitoring-network prêts"
    ;;

  traefik)
    "$0" networks
    echo "🚀 Déploiement Traefik..."
    docker compose -f "$ROOT_DIR/traefik/docker-compose.yml" up -d
    echo "✅ Traefik lancé"
    ;;

  monitoring)
    "$0" networks
    echo "🚀 Déploiement monitoring (prometheus, loki, grafana, promtail, cadvisor, alertmanager, crowdsec)..."
    docker compose -f "$ROOT_DIR/monitoring/compose.monitoring.yml" \
      --env-file "$ROOT_DIR/monitoring/.env.monitoring" up -d
    echo "✅ Monitoring lancé"
    ;;

  prod)
    "$0" networks
    echo "🚀 Déploiement portfolio PROD..."
    docker compose -f "$ROOT_DIR/compose.yml" --env-file "$ROOT_DIR/.env.prod" up -d
    echo "✅ Portfolio PROD lancé"
    ;;

  staging)
    "$0" networks
    echo "🧪 Déploiement portfolio STAGING..."
    docker compose -f "$ROOT_DIR/compose.yml" --env-file "$ROOT_DIR/.env.staging" up -d
    echo "✅ Portfolio STAGING lancé"
    ;;

  all)
    "$0" networks
    "$0" traefik
    "$0" monitoring
    "$0" prod
    echo "✅ Stack complète (traefik + monitoring + prod) déployée"
    ;;

  help|*)
    echo "Usage: $0 <networks|traefik|monitoring|prod|staging|all>"
    echo ""
    echo "  networks   → Crée traefik-web + monitoring-network si absents"
    echo "  traefik    → Déploie Traefik"
    echo "  monitoring → Déploie prometheus/loki/grafana/promtail/cadvisor/alertmanager/crowdsec"
    echo "  prod       → Déploie le portfolio (prod)"
    echo "  staging    → Déploie le portfolio (staging)"
    echo "  all        → traefik + monitoring + prod"
    exit 1
    ;;
esac
