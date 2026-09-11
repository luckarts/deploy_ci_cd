#!/usr/bin/env bash
# Setup Alertmanager with email notifications via Brevo
#
# Usage:
#   ./deploy/scripts/setup-alertmanager.sh
#
# Prerequisites:
#   - S1-S3 deployed (Prometheus + Grafana + Loki running)
#   - ALERTMANAGER_SMTP_PASSWORD and ALERTMANAGER_SMTP_USERNAME set in environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Creating Alertmanager directories..."
mkdir -p monitoring/alertmanager/templates

echo "Copying configuration files..."
cp monitoring/alertmanager/alertmanager.yml monitoring/alertmanager/alertmanager.yml
cp monitoring/alertmanager/templates/email.tmpl monitoring/alertmanager/templates/email.tmpl
cp monitoring/prometheus/prometheus.yml monitoring/prometheus/prometheus.yml

echo "Starting Alertmanager..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml up -d alertmanager

echo "Reloading Prometheus configuration..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml exec prometheus \
  kill -HUP 1 2>/dev/null || \
  docker compose -f compose.yml -f monitoring/compose.monitoring.yml restart prometheus

echo "Waiting for Alertmanager to start..."
sleep 5

echo "Checking Alertmanager status..."
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool 2>/dev/null || \
  echo "Alertmanager not yet reachable — check 'docker compose logs alertmanager'"

echo ""
echo "Alertmanager deployed."
echo "Alertes envoyées à luc.bachelerieart@gmail.com via Brevo SMTP."