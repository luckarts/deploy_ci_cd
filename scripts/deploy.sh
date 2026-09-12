#!/bin/sh
# deploy.sh — Déploiement de l'infra partagée (orchestrateur transverse).
# Usage : ./deploy.sh <networks|traefik|monitoring|registry|watchtower|all>
#
# Ce repo NE contient PAS les apps (portfolio, poker_training) — chacune
# garde son compose.yml + .env dans son propre projet. Ici : uniquement
# ce qui est partagé entre tous les projets (traefik, monitoring, registry
# docker, watchtower).
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

  registry)
    echo "🚀 Déploiement registry Docker..."
    docker compose -f "$ROOT_DIR/registry/docker-compose.yml" up -d
    echo "✅ Registry lancé"
    ;;

  watchtower)
    "$SCRIPT_DIR/deploy-watchtower.sh" both
    ;;

  all)
    "$0" networks
    "$0" traefik
    "$0" monitoring
    "$0" registry
    "$0" watchtower
    echo "✅ Infra partagée (traefik + monitoring + registry + watchtower) déployée"
    echo "ℹ️  Les apps (portfolio, poker_training) se déploient depuis leur propre repo,"
    echo "   une fois traefik-web + monitoring-network prêts."
    ;;

  help|*)
    echo "Usage: $0 <networks|traefik|monitoring|registry|watchtower|all>"
    echo ""
    echo "  networks   → Crée traefik-web + monitoring-network si absents"
    echo "  traefik    → Déploie Traefik"
    echo "  monitoring → Déploie prometheus/loki/grafana/promtail/cadvisor/alertmanager/crowdsec"
    echo "  registry   → Déploie le registry Docker privé"
    echo "  watchtower → Déploie Watchtower (prod + staging)"
    echo "  all        → traefik + monitoring + registry + watchtower"
    exit 1
    ;;
esac
