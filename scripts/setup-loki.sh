#!/usr/bin/env bash
# Setup Loki + Promtail for centralized Docker logs
#
# Usage:
#   ./deploy/scripts/setup-loki.sh
#
# Prerequisites:
#   - S1-S2 deployed (Prometheus + Grafana running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Creating Loki and Promtail directories..."
mkdir -p monitoring/loki monitoring/promtail

echo "Copying configuration files..."
cp monitoring/loki/loki.yml monitoring/loki/loki.yml
cp monitoring/promtail/promtail.yml monitoring/promtail/promtail.yml
cp monitoring/grafana/datasources/loki.yml monitoring/grafana/datasources/loki.yml

echo "Starting Loki and Promtail..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml up -d loki promtail

echo "Waiting for services to start..."
sleep 10

echo "Checking Loki readiness..."
curl -s http://localhost:3100/ready

echo ""
echo "Checking Loki labels..."
curl -s http://localhost:3100/loki/api/v1/labels | python3 -m json.tool 2>/dev/null || \
  echo "Loki not yet ready — check 'docker compose logs loki'"

echo ""
echo "Loki + Promtail deployed."
echo "Logs are now available in Grafana Explore (datasource: Loki)"