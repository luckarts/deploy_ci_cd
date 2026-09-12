#!/usr/bin/env bash
# deploy-watchtower.sh — Déploiement de Watchtower (prod ou staging)
# Usage : ./deploy-watchtower.sh <prod|staging>
#   ./deploy-watchtower.sh prod     → lance watchtower, active scope prod
#   ./deploy-watchtower.sh staging  → lance watchtower, active scope staging (dry-run)
#   ./deploy-watchtower.sh down     → arrête watchtower

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$COMPOSE_DIR/compose.watchtower.yml"

case "${1:-help}" in
  prod)
    echo "🚀 Déploiement Watchtower PROD..."
    docker compose -f "$COMPOSE_FILE" up -d watchtower-prod
    echo "✅ Watchtower PROD lancé (scope=prod, redéploiement actif)"
    echo "   Logs : docker logs watchtower-prod --tail 10 -f"
    ;;

  staging)
    echo "🧪 Déploiement Watchtower STAGING (dry-run)..."
    docker compose -f "$COMPOSE_FILE" up -d watchtower-staging
    echo "✅ Watchtower STAGING lancé (scope=staging, MONITOR ONLY)"
    echo "   Logs : docker logs watchtower-staging --tail 10 -f"
    ;;

  both)
    echo "🚀 Déploiement Watchtower PROD + STAGING..."
    docker compose -f "$COMPOSE_FILE" up -d watchtower-prod watchtower-staging
    echo "✅ Watchtower PROD et STAGING lancés"
    ;;

  down)
    echo "🛑 Arrêt de Watchtower..."
    docker compose -f "$COMPOSE_FILE" down
    echo "✅ Watchtower arrêté"
    ;;

  status)
    echo "📊 Statut Watchtower :"
    docker ps --filter name=watchtower --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    ;;

  run-once)
    echo "🔄 Forcer un scan immédiat..."
    docker exec watchtower-prod watchtower --run-once 2>&1 | head -20 &
    docker exec watchtower-staging watchtower --run-once 2>&1 | head -20 &
    wait
    echo "✅ Scans déclenchés"
    ;;

  logs)
    echo "📝 Logs Watchtower :"
    docker logs watchtower-prod --tail 20
    echo "---"
    docker logs watchtower-staging --tail 20
    ;;

  help|*)
    echo "Usage: $0 <prod|staging|both|down|status|run-once|logs>"
    echo ""
    echo "  prod     → Déploie Watchtower prod (redéploiement automatique)"
    echo "  staging  → Déploie Watchtower staging (dry-run / monitor only)"
    echo "  both     → Déploie les deux instances"
    echo "  down     → Arrête toutes les instances Watchtower"
    echo "  status   → Affiche le statut des conteneurs Watchtower"
    echo "  run-once → Force un scan immédiat (pour tester)"
    echo "  logs     → Affiche les logs récents"
    exit 1
    ;;
esac