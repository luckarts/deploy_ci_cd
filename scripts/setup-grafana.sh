#!/usr/bin/env bash
# Setup Grafana with Prometheus datasource and dashboards
#
# Usage:
#   ./deploy/scripts/setup-grafana.sh
#
# Prerequisites:
#   - S1 deployed (Prometheus + exporters running)
#   - DNS record monitoring.bachelart.fr pointing to the server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Creating Grafana directories..."
mkdir -p monitoring/grafana/datasources monitoring/grafana/dashboards

echo "Copying Grafana configuration..."
cp monitoring/grafana/datasources/prometheus.yml monitoring/grafana/datasources/prometheus.yml
cp monitoring/grafana/dashboards/dashboard.json monitoring/grafana/dashboards/dashboard.json
cp monitoring/grafana/dashboards/dashboards.yaml monitoring/grafana/dashboards/dashboards.yaml
cp monitoring/grafana/grafana.ini monitoring/grafana/grafana.ini

echo "Starting Grafana..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml up -d grafana

echo "Waiting for Grafana to start..."
sleep 15

echo "Checking Grafana health..."
curl -I https://monitoring.bachelart.fr 2>/dev/null || \
  echo "Grafana not yet reachable — check 'docker compose logs grafana'"

echo ""
echo "Grafana deployed: https://monitoring.bachelart.fr"
echo "Admin user: admin"
echo "Admin password: defined in GRAFANA_ADMIN_PASSWORD env var (default: admin)"